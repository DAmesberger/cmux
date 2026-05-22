import Foundation

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

        // Watch for the closed event so the workspace can update its state.
        let eventsChannel = self.channel
        Task { [weak self] in
            for await event in eventsChannel.events {
                if case .closed(let reason, let message, _) = event {
                    guard let self else { break }
                    await MainActor.run { self.onClose?(reason, message) }
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
