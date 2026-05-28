import Foundation

@MainActor
protocol RemoteSessionSyncCoordinatorDelegate: AnyObject {
    func syncCoordinator(
        _ coordinator: RemoteSessionSyncCoordinator,
        discoveredNewSession entry: Ghostty.SessionListEntry,
        on connection: Ghostty.SSHConnection
    )
    func syncCoordinator(
        _ coordinator: RemoteSessionSyncCoordinator,
        sessionEnded groupID: UUID
    )
    func syncCoordinator(
        _ coordinator: RemoteSessionSyncCoordinator,
        sessionMetaChanged entry: Ghostty.SessionListEntry
    )
}

/// Diffs the daemon's session list against a last-known snapshot and
/// notifies its delegate of additions / removals / metadata changes.
///
/// Used to be a continuous 8s poll. Now strictly on-demand: callers
/// invoke `refreshNow()` when the SSH connection just (re)connected
/// and when the command palette opens. That covers the two real
/// reasons we'd want to learn about externally-initiated session
/// changes (another cmux instance, daemon-side eviction) without
/// burning a SSH round-trip every 8 seconds in single-user setups.
///
/// One instance per `WorkspaceSSHIntegration`.
@MainActor
final class RemoteSessionSyncCoordinator {
    private let connection: Ghostty.SSHConnection
    weak var delegate: RemoteSessionSyncCoordinatorDelegate?

    // groupID → last-seen entry for diff computation
    private var knownSessions: [UUID: Ghostty.SessionListEntry] = [:]
    private var refreshTask: Task<Void, Never>?

    init(connection: Ghostty.SSHConnection, knownGroupIDs: Set<UUID> = []) {
        self.connection = connection
        // Pre-populate knownSessions with stub entries so existing
        // workspaces don't trigger "new session" callbacks on the
        // first post-connect refresh.
        for id in knownGroupIDs {
            knownSessions[id] = Ghostty.SessionListEntry(
                groupID: id,
                label: "",
                surfaceCount: 1,
                createdAt: .distantPast
            )
        }
    }

    /// Trigger a one-shot list-sessions + diff. Coalesces concurrent
    /// callers — if a refresh is already in flight, the second caller
    /// piggybacks on it instead of issuing a duplicate SSH request.
    func refreshNow() {
        if refreshTask != nil { return }
        refreshTask = Task { [weak self] in
            await self?.pollOnce()
            self?.refreshTask = nil
        }
    }

    /// Cancel any in-flight refresh. Called from teardown paths so we
    /// don't fire delegate callbacks against a dead workspace.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Notify the coordinator that a local workspace was closed so it won't fire
    /// spurious "sessionEnded" callbacks for user-initiated closes.
    func didCloseWorkspace(groupID: UUID) {
        knownSessions.removeValue(forKey: groupID)
    }

    // MARK: - Private

    private func pollOnce() async {
        guard let entries = try? await connection.listSessions() else { return }

        let nowByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.groupID, $0) })
        let nowIDs = Set(nowByID.keys)
        let knownIDs = Set(knownSessions.keys)

        let addedIDs = nowIDs.subtracting(knownIDs)
        let removedIDs = knownIDs.subtracting(nowIDs)
        let commonIDs = knownIDs.intersection(nowIDs)

        for id in addedIDs {
            let entry = nowByID[id]!
            // Only auto-surface sessions that have live surfaces (detached ones go to palette only).
            guard entry.surfaceCount > 0 else { continue }
            knownSessions[id] = entry
            delegate?.syncCoordinator(self, discoveredNewSession: entry, on: connection)
        }

        for id in removedIDs {
            knownSessions.removeValue(forKey: id)
            delegate?.syncCoordinator(self, sessionEnded: id)
        }

        for id in commonIDs {
            let old = knownSessions[id]!
            let new = nowByID[id]!
            if old.label != new.label || old.color != new.color || old.status != new.status {
                knownSessions[id] = new
                delegate?.syncCoordinator(self, sessionMetaChanged: new)
            } else {
                knownSessions[id] = new
            }
        }

        // Track newly-visible detached sessions in knownSessions so they don't
        // fire repeated palette hints, but don't delegate them.
        for id in addedIDs where nowByID[id]!.surfaceCount == 0 {
            knownSessions[id] = nowByID[id]!
        }
    }
}
