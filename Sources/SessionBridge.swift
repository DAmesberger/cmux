import Foundation

/// Daemon-side identity for a remote terminal surface, decoded from the
/// 36-byte service_ack payload libghostty delivers on `Event.opened`.
///
/// Wire format (matches `cmux_terminal_service_ack` packed by the M3 bridge
/// in `ghostty/src/apprt/embedded/ssh_capi.zig`):
///
/// ```
/// offset  size  field
/// ------  ----  -----
///   0     16    group_id   (RFC 4122 / big-endian byte order)
///  16     16    surface_id (RFC 4122 / big-endian byte order)
///  32      4    history_rows (little-endian u32)
/// ```
///
/// Persisted in `SessionTerminalPanelSnapshot.remoteSurfaceID` so cmux
/// restart can re-attach to the same daemon-side PTY.
struct RemoteSurfaceIdentity: Equatable, Sendable {
    let groupID: UUID
    let surfaceID: UUID
    let historyRows: UInt32

    /// Decode the 36-byte service_ack buffer. Returns nil if `data` is the
    /// wrong size — callers should treat that as a daemon protocol error
    /// and fall back to `onReady` semantics only.
    static func decode(_ data: Data) -> RemoteSurfaceIdentity? {
        guard data.count == 36 else { return nil }
        return data.withUnsafeBytes { raw -> RemoteSurfaceIdentity? in
            guard let base = raw.baseAddress else { return nil }
            let groupBytes = base.assumingMemoryBound(to: UInt8.self)
            let surfaceBytes = groupBytes.advanced(by: 16)
            let group = UUID(uuid: (
                groupBytes[0],  groupBytes[1],  groupBytes[2],  groupBytes[3],
                groupBytes[4],  groupBytes[5],  groupBytes[6],  groupBytes[7],
                groupBytes[8],  groupBytes[9],  groupBytes[10], groupBytes[11],
                groupBytes[12], groupBytes[13], groupBytes[14], groupBytes[15]
            ))
            let surface = UUID(uuid: (
                surfaceBytes[0],  surfaceBytes[1],  surfaceBytes[2],  surfaceBytes[3],
                surfaceBytes[4],  surfaceBytes[5],  surfaceBytes[6],  surfaceBytes[7],
                surfaceBytes[8],  surfaceBytes[9],  surfaceBytes[10], surfaceBytes[11],
                surfaceBytes[12], surfaceBytes[13], surfaceBytes[14], surfaceBytes[15]
            ))
            // history_rows is packed little-endian per the M3 C bridge.
            let rowsPtr = surfaceBytes.advanced(by: 16)
            let rowsLE = UInt32(rowsPtr[0])
                | (UInt32(rowsPtr[1]) << 8)
                | (UInt32(rowsPtr[2]) << 16)
                | (UInt32(rowsPtr[3]) << 24)
            return RemoteSurfaceIdentity(
                groupID: group,
                surfaceID: surface,
                historyRows: rowsLE
            )
        }
    }
}

/// Per-terminal-panel bridge over a `Ghostty.SSHChannel<Ghostty.TerminalService>`.
///
/// One `SessionBridge` is created for each remote terminal panel. It owns the
/// channel returned by `SSHConnection.attachSurface(groupID:surfaceID:size:label:)`
/// and wires its async streams to caller-supplied callbacks so the Ghostty
/// surface can feed bytes and receive resize notifications without touching the
/// channel directly.
///
/// All callbacks are delivered on `MainActor`; the send/resize/close methods
/// may be called from any concurrency context.
@MainActor
final class SessionBridge {

    // MARK: Identity

    let surfaceID: UUID

    // MARK: Callbacks

    /// Called with each chunk of PTY bytes that arrives from the remote shell.
    var onOutput: (([UInt8]) -> Void)?

    /// Called once when the channel is live and the daemon has accepted the
    /// surface attachment. Safe to start sending keystrokes after this fires.
    var onReady: (() -> Void)?

    /// Called once with the decoded daemon-side identity, alongside `onReady`.
    /// Provides the authoritative `groupID` and `surfaceID` the daemon
    /// recorded for this attachment, so cmux can persist them in session
    /// snapshots and reattach the same remote PTY across restarts.
    ///
    /// Fires only when the 36-byte service_ack decodes cleanly. On a
    /// malformed ack `onReady` still fires but this callback does not — the
    /// surface remains live but won't be persistable as a reattach target.
    var onOpenedDetails: ((RemoteSurfaceIdentity) -> Void)?

    /// Called exactly once when the channel closes (normal exit, transport
    /// drop, or explicit close). After this fires the bridge is dead;
    /// discard and do not reuse.
    var onClose: ((Ghostty.SSHChannel<Ghostty.TerminalService>.CloseReason, String?) -> Void)?

    // MARK: Private storage

    private let channel: Ghostty.SSHChannel<Ghostty.TerminalService>

    // MARK: Init

    /// Attach a terminal surface on `connection` and start forwarding I/O.
    ///
    /// - Parameters:
    ///   - connection: The live `SSHConnection` for the remote workspace.
    ///   - groupID: Session group to attach (pass nil for a new session).
    ///   - surfaceID: Surface identity for reconnect continuity.
    ///   - size: Initial terminal dimensions.
    ///   - label: Human-readable label shown in the daemon session list.
    init(
        connection: Ghostty.SSHConnection,
        groupID: UUID?,
        surfaceID: UUID,
        size: Ghostty.TerminalSize,
        label: String
    ) throws {
        self.surfaceID = surfaceID
        self.channel = try connection.attachSurface(
            groupID: groupID,
            surfaceID: surfaceID,
            size: size,
            label: label
        )

        // Forward PTY output to the surface parser. The Task is detached so
        // it survives beyond the init call frame; [weak self] prevents a
        // retain cycle if the bridge is discarded before the stream ends.
        let outputChannel = self.channel
        Task { [weak self] in
            for await data in outputChannel.output {
                guard let self else { break }
                let bytes = Array(data)
                await MainActor.run { self.onOutput?(bytes) }
            }
        }

        // Watch for opened and closed events.
        let eventsChannel = self.channel
        Task { [weak self] in
            for await event in eventsChannel.events {
                guard let self else { break }
                switch event {
                case .opened(let serviceAck, _):
                    let identity = RemoteSurfaceIdentity.decode(serviceAck)
                    await MainActor.run {
                        self.onReady?()
                        if let identity {
                            self.onOpenedDetails?(identity)
                        }
                    }
                case .closed(let reason, let message, _):
                    await MainActor.run { self.onClose?(reason, message) }
                    return
                default:
                    break
                }
            }
        }
    }

    // MARK: Public API

    /// Write keystroke bytes into the remote PTY.
    func send(_ bytes: [UInt8]) async throws {
        try await channel.write(Data(bytes))
    }

    /// Notify the remote end of a viewport resize.
    ///
    /// Terminal resize flows through the Ghostty surface API
    /// (`surfaceResized` / `ghostty_surface_set_size`) rather than a
    /// channel write — libghostty forwards the new dimensions to the
    /// daemon via the existing surface attachment. This method is a
    /// forward-compatibility hook for callers that hold a `SessionBridge`
    /// reference and want a single point to trigger the resize.
    func resize(_ size: Ghostty.TerminalSize) {
        // Resize is driven by the Ghostty app-surface layer; no direct
        // channel write needed here. The parameter is accepted so call
        // sites compile cleanly while the surface-resize path is wired in
        // by the workspace coordinator.
        _ = size
    }

    /// Close the channel with a NORMAL reason. The `onClose` callback will
    /// fire once the close round-trip completes.
    func close() {
        channel.close()
    }
}
