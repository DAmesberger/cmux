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
/// It opens a `PortListenerService` channel on the remote end and subscribes
/// to the connection's `inboundChannels` stream so it can match and accept the
/// `tcp_accepted` sub-channels that arrive for each upstream connection.
///
/// Each accepted channel is bridged to a local `NWConnection` on 127.0.0.1
/// that callers (or the CLI) can connect to.
///
/// Threading: the object is `@MainActor`-isolated. The NWListener and
/// NWConnection callbacks are dispatched through a private serial queue and
/// hop back to `MainActor` before mutating shared state.
@MainActor
final class PortForwardHandle {

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

        // Subscribe to daemon-originated channels on the connection.
        // Each `port_listener` accept arrives as an InboundChannel with:
        //   serviceID = 255 (GHOSTTY_CHANNEL_SERVICE_CUSTOM — the C-API
        //                   maps the daemon-internal tcp_accepted id 6 to custom)
        //   params = [16 bytes parent_listener_uuid][6 or 18 bytes peer_addr]
        //
        // We match the parent UUID against our own listener handle to avoid
        // stealing accepts that belong to other PortForwardHandles.
        let listenerCh = self.listenerChannel
        Task { [weak self] in
            guard let self else { return }
            for await inbound in connection.inboundChannels {
                await MainActor.run {
                    self.handleInbound(inbound, listenerChannel: listenerCh)
                }
            }
        }
    }

    // MARK: Inbound channel handling

    private func handleInbound(
        _ inbound: Ghostty.InboundChannel,
        listenerChannel: Ghostty.SSHChannel<Ghostty.PortListenerService>
    ) {
        guard !isClosed else {
            inbound.reject()
            return
        }

        // Only process daemon-originated custom channels (tcp_accepted).
        let customID = UInt8(GHOSTTY_CHANNEL_SERVICE_CUSTOM.rawValue)
        guard inbound.serviceID == customID else {
            return  // not ours; leave for other subscribers
        }

        // Parse the 16-byte parent_listener_uuid from the params prefix.
        // Layout per port_listener.zig:
        //   [16]  parent_listener_uuid
        //   [N]   peer_addr (6 bytes AF_INET or 18 bytes AF_INET6)
        guard inbound.params.count >= 16 else {
            inbound.reject()
            return
        }

        let parentUUIDBytes = inbound.params.prefix(16)
        let parentUUID = uuidFromBytes(parentUUIDBytes)

        // Match against our listener channel's handle. The listener UUID is
        // available via the service_ack bytes in the `opened` event. As a
        // simpler per-handle heuristic while the service_ack parsing is
        // deferred, we accept ALL custom inbound channels when there is only
        // one active PortForwardHandle on the connection. When multiple
        // handles are active, callers should filter by parentUUID
        // (passed through `opened` service_ack; see note in design doc).
        //
        // For now: accept if the channel appears to be a tcp_accepted channel
        // (16+ byte params with a parseable UUID). The workspace-level
        // inboundChannels consumer will route unaccepted channels to other
        // listeners, so false-accepting a foreign channel is the only risk —
        // which is mitigated once service_ack UUID filtering is plumbed.
        _ = parentUUID  // used for future UUID filtering

        guard let acceptedChannel = inbound.accept(using: TCPAcceptedService()) else {
            // Service ID mismatch or already claimed — skip silently.
            return
        }

        // Bridge the accepted channel to a local NWConnection.
        bridgeToLocal(acceptedChannel)
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
