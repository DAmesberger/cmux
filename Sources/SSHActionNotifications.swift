import AppKit
import Foundation

// Notification names posted from GhosttyTerminalView.handleAction when
// libghostty fires an SSH action callback (e.g. from an ssh_* keybinding).
// Each notification carries the workspace UUID in userInfo so the handler
// can resolve the correct WorkspaceSSHIntegration.
enum SSHActionNotification {
    static let createSession  = Notification.Name("com.cmux.ssh.createSession")
    static let sessionAttach  = Notification.Name("com.cmux.ssh.sessionAttach")
    static let renameSession  = Notification.Name("com.cmux.ssh.renameSession")
    static let deleteSession  = Notification.Name("com.cmux.ssh.deleteSession")
    static let toggleSizeMode = Notification.Name("com.cmux.ssh.toggleSizeMode")
    static let manageSession  = Notification.Name("com.cmux.ssh.manageSession")
    /// Posted by the File menu, the configurable shortcut, and the libghostty
    /// `ssh_create_session` keybinding. Opens the in-app SSH Connect sheet so
    /// the dispatch passes the cmuxOnly descendant check (the CLI is spawned
    /// as a child of the app).
    static let requestConnect = Notification.Name("com.cmux.ssh.requestConnect")

    /// UUID of the cmux workspace that dispatched the action.
    static let workspaceIDKey = "cmux.ssh.workspaceID"
}

/// Installed once by AppDelegate on launch. Observes SSH action notifications
/// and routes them to the appropriate workspace or UI entry point.
@MainActor
final class SSHActionObserver {

    private var tokens: [NSObjectProtocol] = []

    func install() {
        let center = NotificationCenter.default

        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
        }

        tokens = [
            on(SSHActionNotification.createSession)  { [weak self] in self?.handleCreateSession($0) },
            on(SSHActionNotification.sessionAttach)  { [weak self] in self?.handleSessionAttach($0) },
            on(SSHActionNotification.renameSession)  { [weak self] in self?.handleRenameSession($0) },
            on(SSHActionNotification.deleteSession)  { [weak self] in self?.handleDeleteSession($0) },
            on(SSHActionNotification.toggleSizeMode) { _ in /* no-op: no size-mode concept in Phase 7 */ },
            on(SSHActionNotification.manageSession)  { [weak self] in self?.handleManageSession($0) },
            on(SSHActionNotification.requestConnect) { [weak self] in self?.handleRequestConnect($0) },
        ]
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Handlers

    private func handleCreateSession(_ note: Notification) {
        // ssh_create_session keybinding → open the in-app SSH Connect sheet,
        // which spawns the cmux CLI as a child of the app (so the cmuxOnly
        // descendant check passes — running `cmux ssh user@host` from a
        // bare shell hits "Broken pipe, errno 32" because that check rejects
        // non-descendant peers; see upstream issues #3089 / #4146 / #3287).
        SSHConnectSheetPresenter.present(on: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private func handleRequestConnect(_ note: Notification) {
        let preferred = (note.object as? NSWindow) ?? NSApp.keyWindow ?? NSApp.mainWindow
        SSHConnectSheetPresenter.present(on: preferred)
    }

    private func handleSessionAttach(_ note: Notification) {
        // ssh_session_attach keybinding → palette where detached sessions listed.
        AppDelegate.shared?.requestCommandPaletteCommands(source: "ssh.sessionAttach")
    }

    private func handleRenameSession(_ note: Notification) {
        guard let (manager, workspace) = resolveWorkspace(from: note),
              workspace.isRemoteWorkspace else { return }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.renameRemoteSession.title",
            defaultValue: "Rename Remote Session"
        )
        alert.informativeText = String(
            localized: "alert.renameRemoteSession.message",
            defaultValue: "Enter a new name for this remote session."
        )
        let input = NSTextField(string: workspace.customTitle ?? workspace.title)
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        input.placeholderString = String(
            localized: "alert.renameRemoteSession.placeholder",
            defaultValue: "Session name"
        )
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let win = alert.window
        win.initialFirstResponder = input
        DispatchQueue.main.async { win.makeFirstResponder(input); input.selectText(nil) }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newLabel = input.stringValue
        manager.setCustomTitle(tabId: workspace.id, title: newLabel)
        workspace.renameRemoteSession(newLabel: newLabel)
    }

    private func handleDeleteSession(_ note: Notification) {
        guard let (manager, workspace) = resolveWorkspace(from: note),
              workspace.isRemoteWorkspace else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "alert.deleteRemoteSession.title",
            defaultValue: "Delete Session on Remote?"
        )
        alert.informativeText = String(
            localized: "alert.deleteRemoteSession.message",
            defaultValue: "This will kill the remote session and all its attached surfaces. The local workspace will also be closed."
        )
        alert.addButton(withTitle: String(
            localized: "alert.deleteRemoteSession.delete",
            defaultValue: "Delete Session"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        workspace.killRemoteSession()
        manager.closeTab(workspace)
    }

    private func handleManageSession(_ note: Notification) {
        // Route to the command palette — remote session entries are listed there.
        AppDelegate.shared?.requestCommandPaletteCommands(source: "ssh.manageSession")
    }

    // MARK: - Helpers

    private func resolveWorkspace(from note: Notification) -> (TabManager, Workspace)? {
        guard let workspaceID = note.userInfo?[SSHActionNotification.workspaceIDKey] as? UUID,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: workspaceID) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        return (manager, workspace)
    }
}
