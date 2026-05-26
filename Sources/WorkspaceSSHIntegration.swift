import Foundation
import Combine
import GhosttyKit

/// Per-workspace coordinator that owns the `Ghostty.SSHConnection` for one remote workspace.
///
/// Terminal surfaces now run libghostty's native `Remote` termio backend via
/// surface-config fields (`ssh_target`/`ssh_session_id`/`ssh_surface_id`/
/// `ssh_label`), so this type no longer owns per-terminal bridges. It keeps
/// the SSH connection alive for the browser proxy + port-forward channels
/// and surfaces session management commands used by the command palette.
@MainActor
final class WorkspaceSSHIntegration {
    let connection: Ghostty.SSHConnection
    @Published private(set) var connectionState: Ghostty.ConnectionState

    /// Port forward handles keyed by PortForwardID.
    var portForwards: [PortForwardID: PortForwardHandle] = [:]
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

        portForwards.values.forEach { $0.close() }
        portForwards.removeAll()

        connection.cancelReconnect()
    }

    // MARK: - Port forwards

    /// Open a port-listener channel, wrap it in a `PortForwardHandle`, store it, and return it.
    func openPortForward(bindHost: String, port: UInt16) throws -> PortForwardHandle {
        let handle = try PortForwardHandle(
            connection: connection,
            bindHost: bindHost,
            port: port
        )
        portForwards[handle.id] = handle
        return handle
    }

    // MARK: - Discovery coordinator (Track E)

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
