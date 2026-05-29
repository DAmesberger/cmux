import Foundation
import GhosttyKit

// MARK: - CmuxControlService

/// Local-only `ChannelService` conformance for the daemon-originated
/// `cmux_control` reverse channel.
///
/// Like `tcp_accepted` (see `PortForwardHandle.TCPAcceptedService`), the daemon
/// maps the internal `cmux_control` wire service id (7) to
/// `GHOSTTY_CHANNEL_SERVICE_CUSTOM` (255) at the C-API bridge
/// (`ssh_capi.zig:inboundOpen`, whose `else => .custom` arm catches any id
/// outside the spec range) before delivering the `InboundChannel`. This type
/// mirrors that mapping so that `InboundChannel.accept(using:)` passes its
/// service-id guard and returns a live `SSHChannel`.
///
/// `encodeParams()` is empty — this service is only used for ACCEPTING the
/// inbound reverse channel, never for opening one.
struct CmuxControlService: Ghostty.ChannelService {
    var cService: ghostty_channel_service_e { GHOSTTY_CHANNEL_SERVICE_CUSTOM }
    func encodeParams() throws -> Data { Data() }
}

// MARK: - RemoteControlChannel

/// Accepts the daemon-originated `cmux_control` reverse channel and runs each
/// framed CLI request received on it through the LOCAL app's socket dispatcher.
///
/// Wire model (newline-delimited, mirroring the local unix socket):
/// the remote agent's `cmux notify ...` connects to a remote-side unix socket
/// (path injected into the remote shell env via `CMUX_SOCKET_PATH` by the
/// daemon). The daemon forwards each line received there back to the client
/// over a `cmux_control` channel. We read those lines off the channel, dispatch
/// each through `TerminalController.shared.handleSocketLine` — the SAME entry
/// point the local socket uses, so notify / notify_target / report_* behave
/// identically — mirror the command/response pair through `publishSocketEvents`
/// (so CmuxSocketEventMapper republishes it to the event bus, no duplication),
/// and write the response back framed (one line per request).
///
/// Health: emits `.ready` once the reverse channel is accepted and the request
/// pump is running, and `.degraded(.channelClosed)` when the channel closes
/// because the underlying transport dropped (so the owner can re-arm on the
/// next `.connected`). It can never demote the workspace `primary` transport.
///
/// Threading: `@MainActor`-isolated. The per-channel pump runs on a detached
/// task; the framed-line dispatch hops through `TerminalController`'s
/// `nonisolated` socket entry point (which applies its own off-main / main
/// execution policy per command).
@MainActor
final class RemoteControlChannel: InboundChannelHandler {
    /// Discriminator prefix carried in the inbound channel's `params` so this
    /// consumer can tell a `cmux_control` reverse channel apart from a
    /// `tcp_accepted` port-forward accept (both arrive as service id 255).
    /// The daemon writes this tag as the channel-open service params.
    static let paramTag = Data("cmuxctl1".utf8)

    /// Maximum bytes we buffer for a single un-terminated request line before
    /// treating the stream as malformed and closing. Mirrors the local socket's
    /// line-oriented protocol; a real CLI request is far smaller than this.
    private static let maxRequestLineBytes = 1 * 1024 * 1024

    private let connection: Ghostty.SSHConnection
    /// The per-connection inbound router this channel registers with. The
    /// router runs the single `inboundChannels` loop and offers each inbound to
    /// `tryHandle`. Held weakly: the router is owned by `WorkspaceSSHIntegration`.
    private weak var router: InboundChannelRouter?
    /// Fired when the reverse channel's health changes (`.ready` /
    /// `.degraded(.channelClosed)`). The owner forwards this into
    /// `dispatchRemote(.capability(.cmuxControl, ...))`.
    private let onHealth: @MainActor (RemoteCapabilityHealth) -> Void

    /// Per-channel state for an accepted reverse channel.
    private final class ChannelEntry {
        let channel: Ghostty.SSHChannel<CmuxControlService>
        /// The per-session token the daemon embedded in the channel params
        /// (bytes after the 8-byte tag). When non-empty, the FIRST framed line
        /// on the channel MUST authenticate against it before any command is
        /// dispatched. Empty means the current daemon embedded no token and the
        /// channel relies on the daemon-side unix-socket auth alone (the client
        /// still enforces the command subset).
        let expectedToken: Data
        /// Becomes true once the per-line handshake has matched `expectedToken`
        /// (or immediately, if `expectedToken` is empty).
        var authenticated: Bool
        init(channel: Ghostty.SSHChannel<CmuxControlService>, expectedToken: Data) {
            self.channel = channel
            self.expectedToken = expectedToken
            self.authenticated = expectedToken.isEmpty
        }
    }

    /// Strongly-held accepted channels keyed by identity so they stay alive
    /// while their pump runs. Cleared when a channel closes.
    private var channels: [ObjectIdentifier: ChannelEntry] = [:]
    private var isClosed = false

    init(
        connection: Ghostty.SSHConnection,
        router: InboundChannelRouter,
        onHealth: @escaping @MainActor (RemoteCapabilityHealth) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.onHealth = onHealth
    }

    /// Register with the per-connection inbound router so the daemon-originated
    /// reverse channel is dispatched here. Idempotent enough for the owner's
    /// start-on-`.connected` path: callers `stop()` an existing instance before
    /// constructing a new one (the owner does this, mirroring `RemoteProxyTunnel`).
    func start() {
        guard !isClosed else { return }
        router?.register(self)
    }

    func stop() {
        guard !isClosed else { return }
        isClosed = true
        router?.unregister(self)
        for entry in channels.values {
            entry.channel.close()
        }
        channels.removeAll()
    }

    // MARK: - Inbound acceptance

    /// Router entry point: offer one daemon-originated inbound channel to the
    /// control channel. Claims a custom (id 255) channel whose params start with
    /// the 8-byte `cmuxctl1` tag; returns `.passed` otherwise so the router can
    /// offer it to the next handler (e.g. a `PortForwardHandle`).
    func tryHandle(_ inbound: Ghostty.InboundChannel) -> InboundChannelDisposition {
        guard !isClosed else {
            return .passed  // stopped: let another live handler claim it
        }

        // Only daemon-originated custom channels (id 255) can be ours.
        let customID = UInt8(GHOSTTY_CHANNEL_SERVICE_CUSTOM.rawValue)
        guard inbound.serviceID == customID else {
            return .passed  // not ours; leave for other subscribers
        }

        // Distinguish the cmux_control reverse channel from a tcp_accepted
        // port-forward accept by the params discriminator tag. A tcp_accepted
        // channel's params start with a 16-byte parent UUID, never our tag.
        guard inbound.params.count >= Self.paramTag.count,
              inbound.params.prefix(Self.paramTag.count) == Self.paramTag else {
            return .passed  // a tcp_accepted (or unknown) custom channel; not ours
        }

        guard let channel = inbound.accept(using: CmuxControlService()) else {
            // Service id mismatch or already claimed — we still consumed the
            // offer (the inbound's one-shot claim is now spent).
            return .claimed
        }

        // Bytes after the 8-byte tag are the per-session token the daemon
        // embedded (if any). When present, the channel must authenticate
        // against it before any command is dispatched.
        let expectedToken = Data(inbound.params.dropFirst(Self.paramTag.count))

        let key = ObjectIdentifier(channel)
        let entry = ChannelEntry(channel: channel, expectedToken: expectedToken)
        channels[key] = entry
        onHealth(.ready)
        startRequestPump(entry, key: key)
        return .claimed
    }

    // MARK: - Request/response pump

    /// Drain framed (newline-delimited) request lines off the channel, dispatch
    /// each through the local socket dispatcher, and write the framed response
    /// back. Also watches channel events to detect a transport-caused close.
    ///
    /// Per-channel state (auth latch) lives on `entry`. The reader hops to
    /// `MainActor` to read/flip `entry.authenticated` because the entry is
    /// `@MainActor`-owned mutable state.
    private func startRequestPump(
        _ entry: ChannelEntry,
        key: ObjectIdentifier
    ) {
        let channel = entry.channel
        // Request reader: accumulate bytes, split on '\n', dispatch each line.
        Task { [weak self, weak channel, weak entry] in
            var pending = Data()
            guard let channel else { return }
            for await data in channel.output {
                guard self != nil else { break }
                pending.append(data)
                if pending.count > RemoteControlChannel.maxRequestLineBytes {
                    // Malformed / oversized; drop the connection.
                    channel.close()
                    break
                }
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<newlineIndex]
                    pending = Data(pending[pending.index(after: newlineIndex)...])
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let entry else { break }
                    await RemoteControlChannel.processLine(trimmed, entry: entry, on: channel)
                }
            }
            // Output ended (peer EOF or channel torn down). Drop our reference.
            await MainActor.run { self?.channels.removeValue(forKey: key) }
        }

        // Event watcher: detect a transport-caused close so the owner can mark
        // the capability degraded and re-arm on the next `.connected`.
        Task { [weak self] in
            for await event in channel.events {
                guard self != nil else { break }
                if case let .closed(reason, _, wasTransport) = event {
                    if wasTransport || reason == .transport || reason == .daemonShutdown {
                        await MainActor.run {
                            self?.onHealth(RemoteCapabilityHealth(
                                state: .degraded,
                                reason: .channelClosed
                            ))
                        }
                    }
                    await MainActor.run {
                        self?.channels.removeValue(forKey: key)
                    }
                    break
                }
            }
        }
    }

    /// Process one framed line. Enforces, in order:
    ///   1. Per-session token handshake: when the daemon embedded a token in
    ///      the channel params, the FIRST line must authenticate against it
    ///      (`auth <token>` / `auth.token <token>`); an unauthenticated channel
    ///      forwards NO command and is dropped on a bad token.
    ///   2. Command subset allowlist: only `notify` / `notify_*` / `report_*`
    ///      are dispatched. Anything else (the full V1/V2 socket surface) is
    ///      rejected without ever reaching `handleSocketLine`, so the network
    ///      cannot drive focus/open/close/send-key/list/etc.
    @MainActor
    private static func processLine(
        _ line: String,
        entry: ChannelEntry,
        on channel: Ghostty.SSHChannel<CmuxControlService>
    ) async {
        if !entry.authenticated {
            // A token was required but not yet presented. The first line must
            // be the matching auth handshake; otherwise drop the channel
            // without forwarding anything.
            guard verifyToken(line: line, expected: entry.expectedToken) else {
                await write("ERROR: cmux_control auth required", on: channel)
                channel.close()
                return
            }
            entry.authenticated = true
            await write("OK: authenticated", on: channel)
            return
        }

        // An explicit auth line on an already-authenticated channel is a no-op
        // ack (the remote CLI may re-send it); never treat it as a command.
        if isAuthLine(line) {
            await write("OK: authenticated", on: channel)
            return
        }

        guard isAllowedCommand(line) else {
            await write("ERROR: command not permitted over cmux_control", on: channel)
            return
        }

        await dispatch(request: line, on: channel)
    }

    /// True if `line` is a command the reverse channel is allowed to dispatch:
    /// the `notify` family and the `report_*` family. The remote network must
    /// not be able to drive the full socket surface (focus/open/close/send/
    /// list/v2 JSON), so everything else is rejected before `handleSocketLine`.
    static func isAllowedCommand(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // v2 JSON commands (the full structured surface) are never allowed.
        if trimmed.hasPrefix("{") { return false }
        let key = trimmed.split(separator: " ", maxSplits: 1).first.map {
            String($0).lowercased()
        } ?? ""
        if key == "notify" { return true }
        if key.hasPrefix("notify_") { return true }
        if key.hasPrefix("report_") { return true }
        return false
    }

    /// True if `line` is an `auth <token>` / `auth.token <token>` handshake.
    private static func isAuthLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("auth ") || lower.hasPrefix("auth.token ")
    }

    /// Constant-time-ish compare of the token in an auth handshake line against
    /// the expected per-session token. Accepts `auth <token>` and
    /// `auth.token <token>`.
    static func verifyToken(line: String, expected: Data) -> Bool {
        guard !expected.isEmpty else { return true }
        let provided: String
        if line.hasPrefix("auth.token ") {
            provided = String(line.dropFirst("auth.token ".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("auth ") {
            provided = String(line.dropFirst("auth ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            return false
        }
        let providedData = Data(provided.utf8)
        guard providedData.count == expected.count, !providedData.isEmpty else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(providedData, expected) { diff |= a ^ b }
        return diff == 0
    }

    /// Run one framed request through the local socket dispatcher and write the
    /// response back on the channel. Dispatch happens on
    /// `TerminalController.shared` (which applies its own execution policy), and
    /// the command/response pair is mirrored to the event bus exactly like the
    /// local socket path.
    private static func dispatch(
        request: String,
        on channel: Ghostty.SSHChannel<CmuxControlService>
    ) async {
        let controller = TerminalController.shared
        let response = controller.handleSocketLine(request)
        controller.publishSocketEvents(command: request, response: response)
        await write(response, on: channel)
    }

    /// Frame `text` as a single newline-terminated line, mirroring the local
    /// socket's reply shape. Collapse interior newlines so a multi-line response
    /// stays one frame on the wire.
    private static func write(
        _ text: String,
        on channel: Ghostty.SSHChannel<CmuxControlService>
    ) async {
        let framed = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        try? await channel.write(Data(framed.utf8))
    }
}
