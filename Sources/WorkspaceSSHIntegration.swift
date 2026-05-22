import Foundation
import Combine
import GhosttyKit

/// Per-workspace coordinator that owns the `Ghostty.SSHConnection` for one remote workspace.
///
/// Tracks B, C, and E populate `sessionBridges`, `portForwards`, and `discoveryCoordinator`
/// respectively. Track A (this file) provides the skeleton: connection lifecycle, state
/// bridging, and the public surface Tracks C/E hang their work onto.
@MainActor
final class WorkspaceSSHIntegration {
    let connection: Ghostty.SSHConnection
    @Published private(set) var connectionState: Ghostty.ConnectionState

    /// Terminal channels keyed by cmux panel UUID. Track C populates this.
    var sessionBridges: [UUID: Ghostty.SSHChannel<Ghostty.TerminalService>] = [:]
    /// Port listener channels. Track C populates this.
    var portForwards: [UUID: Ghostty.SSHChannel<Ghostty.PortListenerService>] = [:]
    /// Session discovery + color-sync coordinator. Track E installs this.
    var discoveryCoordinator: AnyObject? {
        get { _discoveryCoordinator }
        set { _discoveryCoordinator = newValue as? RemoteSessionSyncCoordinator }
    }
    private var _discoveryCoordinator: RemoteSessionSyncCoordinator?

    private var stateObserverTask: Task<Void, Never>?

    init(config: WorkspaceRemoteConfiguration, app: ghostty_app_t?) throws {
        let cfg = config.ghosttyConfig()
        self.connection = try Ghostty.SSHConnection(
            config: cfg,
            hostKey: config.hostKeyPolicy,
            app: app
        )
        self.connectionState = .connecting

        let conn = self.connection
        self.stateObserverTask = Task { [weak self] in
            for await state in conn.state {
                guard let self else { return }
                self.connectionState = state
            }
        }
    }

    func tearDown() {
        stateObserverTask?.cancel()
        stateObserverTask = nil

        _discoveryCoordinator?.stop()
        _discoveryCoordinator = nil

        sessionBridges.values.forEach { $0.close() }
        sessionBridges.removeAll()
        portForwards.values.forEach { $0.close() }
        portForwards.removeAll()

        connection.cancelReconnect()
    }

    /// Installs (or replaces) the session discovery coordinator and starts polling.
    func attachDiscoveryCoordinator(_ coord: AnyObject) {
        _discoveryCoordinator?.stop()
        _discoveryCoordinator = coord as? RemoteSessionSyncCoordinator
        _discoveryCoordinator?.start()
    }

    // MARK: - Session management (Track E)

    /// Rename the remote session identified by `groupID`. Fire-and-forget.
    func renameRemoteSession(groupID: UUID, newLabel: String) {
        connection.renameSession(groupID: groupID, label: newLabel)
    }

    /// Kill the remote session identified by `groupID`. Fire-and-forget.
    func killRemoteSession(groupID: UUID) {
        connection.killSession(groupID: groupID)
    }

    /// Query the remote session list; used by the command palette. Returns empty on error.
    func listSessionsForPalette() async -> [Ghostty.SessionListEntry] {
        (try? await connection.listSessions()) ?? []
    }
}
