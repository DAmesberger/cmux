import Foundation
import Combine
import GhosttyKit

/// Per-workspace coordinator that owns the `Ghostty.SSHConnection` for one remote workspace.
///
/// Track C populates `sessionBridges` and `portForwards` via `attachTerminal` and
/// `openPortForward`. Track E installs `discoveryCoordinator`. Track A (this file) owns
/// the connection lifecycle and the management methods those tracks call.
@MainActor
final class WorkspaceSSHIntegration {
    let connection: Ghostty.SSHConnection
    @Published private(set) var connectionState: Ghostty.ConnectionState

    /// Terminal session bridges keyed by the terminal panel's surfaceID. Track C populates this.
    var sessionBridges: [UUID: SessionBridge] = [:]
    /// Port forward handles keyed by PortForwardID. Track C populates this.
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

        sessionBridges.values.forEach { $0.close() }
        sessionBridges.removeAll()
        portForwards.values.forEach { $0.close() }
        portForwards.removeAll()

        connection.cancelReconnect()
    }

    // MARK: - Terminal channel management (Track C)

    /// Open a terminal channel, wrap it in a `SessionBridge`, store it, and return it.
    ///
    /// The bridge is keyed by `surfaceID` so the workspace can look it up when the
    /// panel closes. Pass `groupID: nil` for a brand-new session; pass the persisted
    /// group UUID for session reattach across cmux restarts.
    func attachTerminal(
        groupID: UUID?,
        surfaceID: UUID,
        size: Ghostty.TerminalSize,
        label: String
    ) throws -> SessionBridge {
        let bridge = try SessionBridge(
            connection: connection,
            groupID: groupID,
            surfaceID: surfaceID,
            size: size,
            label: label
        )
        sessionBridges[surfaceID] = bridge
        return bridge
    }

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
