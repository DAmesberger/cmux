import Foundation
import Network
import GhosttyKit

// MARK: - PortForwardID

/// Opaque stable identity for an active port forward, suitable for use as a
/// dictionary key or in socket-API responses.
struct PortForwardID: Hashable, Codable {
    let id: UUID
    init() { self.id = UUID() }
}

// MARK: - PortForwardError

/// Errors surfaced when opening a port forward.
enum PortForwardError: Swift.Error, Equatable {
    /// A second concurrent forward was requested. FINDING A: `tryHandle`
    /// cannot match a daemon-originated `tcp_accepted` accept to its own
    /// listener (the daemon's `parent_listener_uuid` is not returned in the
    /// port_listener service_ack), so with the deterministic
    /// first-claim-wins `InboundChannelRouter` the first-registered forward
    /// would claim ALL accepts for ALL forwards. Until the listener UUID is
    /// plumbed through the ack, only one active forward per connection is
    /// supported.
    case multipleForwardsUnsupported
}

// MARK: - TCPAcceptedService

/// Local-only `ChannelService` conformance for daemon-originated
/// port-listener accept channels.
///
/// The daemon maps the internal `tcp_accepted` wire service id (6) to
/// `GHOSTTY_CHANNEL_SERVICE_CUSTOM` (255) via the C-API bridge
/// (`ssh_capi.zig:inboundOpen`) before delivering the `InboundChannel`.
/// This type mirrors that mapping so that `InboundChannel.accept(using:)`
/// passes its service-id guard and returns a live `SSHChannel`.
///
/// The `encodeParams()` result is empty — this service is only used for
/// ACCEPTING inbound channels, not for opening new ones, so the params
/// body is irrelevant.
private struct TCPAcceptedService: Ghostty.ChannelService {
    var cService: ghostty_channel_service_e { GHOSTTY_CHANNEL_SERVICE_CUSTOM }
    func encodeParams() throws -> Data { Data() }
}

// MARK: - PortForwardHandle

/// Manages a `PortListenerService` channel and the NWConnections that result
/// from each accepted inbound TCP stream.
///
/// One `PortForwardHandle` is created per "cmux forward-port <port>" request.
/// It opens a `PortListenerService` channel on the remote end. The
/// `tcp_accepted` sub-channels that arrive for each upstream connection are
/// delivered through the per-connection `InboundChannelRouter` (owned by
/// `WorkspaceSSHIntegration`), which offers each daemon-originated inbound to
/// this handle's `tryHandle` rather than each handle running its own
/// `inboundChannels` loop.
///
/// Each accepted channel is bridged to a local `NWConnection` on 127.0.0.1
/// that callers (or the CLI) can connect to.
///
/// Threading: the object is `@MainActor`-isolated. The NWListener and
/// NWConnection callbacks are dispatched through a private serial queue and
/// hop back to `MainActor` before mutating shared state.
@MainActor
final class PortForwardHandle: InboundChannelHandler {

    // MARK: Public surface

    let id: PortForwardID

    /// The host and port the remote daemon is listening on.
    let bindHost: String
    let bindPort: UInt16

    /// Called when the forward is torn down.
    var onClosed: (() -> Void)?

    // MARK: Private storage

    private let listenerChannel: Ghostty.SSHChannel<Ghostty.PortListenerService>
    /// channel_id → active NWConnection (local client side).
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let ioQueue = DispatchQueue(label: "cmux.port-forward.io", qos: .userInitiated)
    private var isClosed = false

    // MARK: Init

    /// Open a port-listener channel and start watching for inbound accepts.
    ///
    /// - Parameters:
    ///   - connection: The live SSH connection for the remote workspace.
    ///   - bindHost: The bind host on the remote side (e.g. "127.0.0.1").
    ///   - port: The port the remote daemon should listen on.
    ///   - listenerID: The UUID of this listener's channel handle, used to
    ///     filter inbound accept events so each `PortForwardHandle` only
    ///     processes its own accepts. Derived from the service_ack bytes in
    ///     the `opened` event (caller is responsible for supplying it once
    ///     known; pass `.zero` to disable filtering until the ack arrives).
    init(
        connection: Ghostty.SSHConnection,
        bindHost: String,
        port: UInt16
    ) throws {
        self.id = PortForwardID()
        self.bindHost = bindHost
        self.bindPort = port
        self.listenerChannel = try connection.openChannel(
            Ghostty.PortListenerService(bindHost: bindHost, port: port)
        )

        // Inbound `tcp_accepted` channels for this forward are delivered by the
        // per-connection `InboundChannelRouter` (owned by
        // `WorkspaceSSHIntegration`) via `tryHandle`, NOT by a per-handle
        // `for await` loop. A single shared loop guarantees no inbound is split
        // between competing consumers (port forwards vs. the cmux_control
        // reverse channel). The owner registers/unregisters this handle.
    }

    // MARK: Inbound channel handling

    /// Router entry point: offer one daemon-originated inbound channel to this
    /// port forward. Claims `tcp_accepted` accepts (custom service id 255 whose
    /// params start with a 16-byte parent_listener_uuid, never the 8-byte
    /// `cmuxctl1` control tag). Returns `.passed` for anything else so the
    /// router can offer it to the next handler (e.g. the control channel).
    func tryHandle(_ inbound: Ghostty.InboundChannel) -> InboundChannelDisposition {
        guard !isClosed else {
            return .passed  // closed: let another live handler claim it
        }

        // Only daemon-originated custom channels (tcp_accepted) can be ours.
        let customID = UInt8(GHOSTTY_CHANNEL_SERVICE_CUSTOM.rawValue)
        guard inbound.serviceID == customID else {
            return .passed
        }

        // The cmux_control reverse channel also arrives as a custom channel,
        // tagged with the 8-byte ASCII "cmuxctl1" discriminator. Leave those
        // for the control-channel handler.
        if inbound.params.count >= RemoteControlChannel.paramTag.count,
           inbound.params.prefix(RemoteControlChannel.paramTag.count) == RemoteControlChannel.paramTag {
            return .passed
        }

        // A tcp_accepted accept's params are:
        //   [16]  parent_listener_uuid
        //   [N]   peer_addr (6 bytes AF_INET or 18 bytes AF_INET6)
        guard inbound.params.count >= 16 else {
            return .passed  // too short for a tcp_accepted accept; not ours
        }

        let parentUUIDBytes = inbound.params.prefix(16)
        let parentUUID = uuidFromBytes(parentUUIDBytes)

        // FINDING A: ideally we would claim ONLY accepts whose 16-byte
        // `parent_listener_uuid` matches THIS handle's own listener. But the
        // daemon generates that UUID (`port_listener.zig`
        // `state.uuid = shared.generateUuid()`) and does NOT return it in the
        // port_listener opened service_ack — the ack carries only the bound
        // host+port (see `port_listener.zig` "Opened service_ack layout"). So
        // the client cannot learn its own listener UUID through the current
        // wire protocol, and a real `parentUUID == ourListenerUUID` match is
        // not implementable without a ghostty wire-format change. Instead,
        // `WorkspaceSSHIntegration.openPortForward` enforces a single active
        // forward per connection (it throws `multipleForwardsUnsupported` on a
        // 2nd), which makes "accept everything" correct: there is exactly one
        // live forward, so every tcp_accepted accept that reaches here is ours.
        // The router only offers an inbound to the next handler when this one
        // `.passed`s, so a single forward never starves the control channel.
        _ = parentUUID  // matched implicitly via the single-forward precondition

        guard let acceptedChannel = inbound.accept(using: TCPAcceptedService()) else {
            // Service ID mismatch or already claimed — we still consumed the
            // offer (the inbound's one-shot claim is now spent).
            return .claimed
        }

        // Bridge the accepted channel to a local NWConnection.
        bridgeToLocal(acceptedChannel)
        return .claimed
    }

    // MARK: Local TCP bridge

    /// Dial a local NWConnection and bi-directionally pump bytes between it
    /// and the accepted SSH channel.
    private func bridgeToLocal(
        _ channel: Ghostty.SSHChannel<TCPAcceptedService>
    ) {
        let parameters = NWParameters.tcp
        // Bind to loopback so only local processes can reach the forward.
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: bindPort) ?? 0,
            using: parameters
        )

        let key = ObjectIdentifier(channel)
        activeConnections[key] = conn

        // Remote → local pump.
        Task { [weak self, weak conn] in
            guard let conn else { return }
            for await data in channel.output {
                conn.send(content: data, completion: .contentProcessed({ _ in }))
            }
            conn.cancel()
            await MainActor.run { self?.activeConnections.removeValue(forKey: key) }
        }

        // Watch for channel close to tear down the NWConnection.
        Task { [weak conn] in
            for await event in channel.events {
                if case .closed = event {
                    conn?.cancel()
                    break
                }
            }
        }

        // Local → remote pump.
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                guard let conn else { return }
                self?.ioQueue.async {
                    self?.pipeLocal(conn: conn, channel: channel)
                }
            case .failed, .cancelled:
                channel.close()
            default:
                break
            }
        }
        conn.start(queue: ioQueue)
    }

    /// Recursively drain `conn` and forward bytes into `channel`.
    private func pipeLocal(
        conn: NWConnection,
        channel: Ghostty.SSHChannel<TCPAcceptedService>
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { try? await channel.write(data) }
            }
            if isComplete || error != nil {
                channel.sendEOF()
                return
            }
            self?.pipeLocal(conn: conn, channel: channel)
        }
    }

    // MARK: Teardown

    /// Close the listener channel and all active bridged connections.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        listenerChannel.close()
        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        onClosed?()
    }
}

// MARK: - UUID parsing helper

/// Reconstruct a `UUID` from 16 raw bytes. Returns nil when the slice is
/// shorter than 16 bytes.
private func uuidFromBytes(_ bytes: Data) -> UUID? {
    guard bytes.count >= 16 else { return nil }
    let t = bytes.prefix(16)
    var raw: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    withUnsafeMutableBytes(of: &raw) { ptr in
        t.copyBytes(to: ptr)
    }
    return UUID(uuid: raw)
}
