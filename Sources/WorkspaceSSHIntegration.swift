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

    /// Single per-connection demultiplexer for the connection's
    /// `inboundChannels` stream. ALL consumers of daemon-originated channels
    /// (port forwards + the cmux_control reverse channel) register here instead
    /// of running their own `for await` loop, so no inbound is split/dropped
    /// between competing iterators. See `InboundChannelRouter`.
    let inboundRouter: InboundChannelRouter

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
        self.inboundRouter = InboundChannelRouter(connection: self.connection)

        let conn = self.connection
        self.stateObserverTask = Task { [weak self] in
            for await state in conn.state {
                guard let self else { return }
                self.connectionState = state
                // Each (re)connect is the right moment to pull a fresh
                // session list — another cmux instance may have added
                // or killed sessions while we were down. Replaces the
                // old continuous-poll loop in
                // `RemoteSessionSyncCoordinator`.
                if case .connected = state {
                    self._discoveryCoordinator?.refreshNow()
                }
            }
        }
    }

    /// Force a one-shot remote-session diff. Called from the command
    /// palette open path so the user sees an up-to-date list without
    /// us running a background poll in the meantime.
    func refreshRemoteSessions() {
        _discoveryCoordinator?.refreshNow()
    }

    func tearDown() {
        stateObserverTask?.cancel()
        stateObserverTask = nil

        _discoveryCoordinator?.stop()
        _discoveryCoordinator = nil

        // Snapshot before closing: each handle's `onClosed` mutates
        // `portForwards` (unregister + removeValue), so iterating the live
        // dictionary while closing would mutate during iteration.
        let handles = Array(portForwards.values)
        portForwards.removeAll()
        handles.forEach { $0.close() }

        inboundRouter.stop()

        connection.cancelReconnect()
    }

    // MARK: - Port forwards

    /// Open a port-listener channel, wrap it in a `PortForwardHandle`, store it, and return it.
    func openPortForward(bindHost: String, port: UInt16) throws -> PortForwardHandle {
        // FINDING A: `PortForwardHandle.tryHandle` cannot yet match a
        // daemon-originated `tcp_accepted` accept to its OWN listener: the
        // daemon generates the `parent_listener_uuid` (`port_listener.zig`
        // `state.uuid = shared.generateUuid()`) and does NOT return it in the
        // port_listener opened service_ack (which carries only the bound
        // host+port — see `port_listener.zig` "Opened service_ack layout"), so
        // the client has no way to learn its listener UUID through the current
        // wire protocol. With the deterministic first-claim-wins
        // `InboundChannelRouter`, a second `PortForwardHandle` would never see
        // its accepts: the first-registered handle would claim ALL accepts for
        // ALL forwards and bridge them to its own port. Until the listener UUID
        // is plumbed through the ack (requires a ghostty wire-format change to
        // `encodeAck`/`parseAck` + the C-API channel-opened path), refuse a
        // second concurrent forward so we never silently mis-route. There is no
        // in-tree caller that opens two forwards today, so this gate is
        // currently unreachable in practice; it makes the latent regression an
        // explicit, debuggable error instead of cross-wired traffic.
        // TODO(port-forward-uuid): once the listener UUID is returned in the
        // port_listener service_ack, plumb it into `PortForwardHandle` and have
        // `tryHandle` claim only accepts whose 16-byte `parent_listener_uuid`
        // matches, then lift this single-forward gate.
        guard portForwards.isEmpty else {
            throw PortForwardError.multipleForwardsUnsupported
        }
        let handle = try PortForwardHandle(
            connection: connection,
            bindHost: bindHost,
            port: port
        )
        portForwards[handle.id] = handle
        // Route tcp_accepted inbound channels for this forward through the
        // shared per-connection router instead of a per-handle loop.
        inboundRouter.register(handle)
        let id = handle.id
        let previousOnClosed = handle.onClosed
        handle.onClosed = { [weak self, weak handle] in
            previousOnClosed?()
            guard let self else { return }
            if let handle { self.inboundRouter.unregister(handle) }
            self.portForwards.removeValue(forKey: id)
        }
        return handle
    }

    // MARK: - Discovery coordinator (Track E)

    /// Installs (or replaces) the session discovery coordinator and
    /// fires one immediate refresh so callers see the current session
    /// list right away. Subsequent refreshes are on-demand via
    /// `refreshRemoteSessions()` (palette open) or auto-triggered on
    /// the next `.connected` state transition.
    func attachDiscoveryCoordinator(_ coord: AnyObject) {
        _discoveryCoordinator?.stop()
        _discoveryCoordinator = coord as? RemoteSessionSyncCoordinator
        _discoveryCoordinator?.refreshNow()
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
