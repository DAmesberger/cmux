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

/// Polls `listSessions()` every 8 seconds while connected and notifies its delegate of
/// discovered, ended, and changed sessions. One instance per `WorkspaceSSHIntegration`.
@MainActor
final class RemoteSessionSyncCoordinator {
    private let connection: Ghostty.SSHConnection
    weak var delegate: RemoteSessionSyncCoordinatorDelegate?

    // groupID → last-seen entry for diff computation
    private var knownSessions: [UUID: Ghostty.SessionListEntry] = [:]
    private var pollTask: Task<Void, Never>?

    init(connection: Ghostty.SSHConnection, knownGroupIDs: Set<UUID> = []) {
        self.connection = connection
        // Pre-populate knownSessions with stub entries so existing workspaces
        // don't trigger "new session" callbacks on reconnect.
        for id in knownGroupIDs {
            knownSessions[id] = Ghostty.SessionListEntry(
                groupID: id,
                label: "",
                surfaceCount: 1,
                createdAt: .distantPast
            )
        }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
