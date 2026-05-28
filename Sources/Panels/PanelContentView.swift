import SwiftUI
import Foundation
import Bonsplit
import AppKit

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    /// Non-nil only when this panel is in a remote workspace AND the
    /// workspace's SSH connection is currently `.connecting`,
    /// `.reconnecting`, `.error`, or `.disconnected`. Drives the
    /// `RemoteReconnectOverlay` that keeps the panel mounted while the
    /// connection cycles, so a network blip doesn't manifest as a
    /// silent panel vanish.
    let remoteConnectionState: WorkspaceRemoteConnectionState?
    let remoteConnectionTarget: String?
    let remoteConnectionDetail: String?
    /// Set while ghostty is uploading the daemon binary. When non-nil
    /// the overlay swaps its headline to "Uploading runtime…" and
    /// renders a progress bar instead of just a spinner.
    let remoteProvisioning: WorkspaceRemoteProvisioning?
    /// Set while ghostty is actively retrying a dropped connection.
    /// Drives the elapsed-time and attempt-counter line in the
    /// overlay so the user can tell how long they've been
    /// disconnected.
    let remoteReconnect: WorkspaceRemoteReconnectInfo?
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        renderedPanel
            .overlay {
                paneDropTargetOverlay
            }
            .overlay {
                remoteReconnectOverlay
            }
    }

    @ViewBuilder
    private var renderedPanel: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalPanelView(
                    panel: terminalPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    onFocus: onFocus,
                    onTriggerFlash: onTriggerFlash
                )
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserPanelView(
                    panel: browserPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .markdown:
            if let markdownPanel = panel as? MarkdownPanel {
                MarkdownPanelView(
                    panel: markdownPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .filePreview:
            if let filePreviewPanel = panel as? FilePreviewPanel {
                FilePreviewPanelView(
                    panel: filePreviewPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .rightSidebarTool:
            if let rightSidebarToolPanel = panel as? RightSidebarToolPanel {
                RightSidebarToolPanelView(
                    panel: rightSidebarToolPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        }
    }

    @ViewBuilder
    private var paneDropTargetOverlay: some View {
        if shouldInstallPaneDropTarget {
            PaneDropTargetRepresentable(dropContext: PaneDropContext(
                workspaceId: workspaceId,
                panelId: panel.id,
                paneId: paneId
            ))
        }
    }

    @ViewBuilder
    private var remoteReconnectOverlay: some View {
        if let state = remoteConnectionState, shouldShowReconnectOverlay(for: state) {
            RemoteReconnectOverlay(
                state: state,
                target: remoteConnectionTarget,
                detail: remoteConnectionDetail,
                provisioning: remoteProvisioning,
                reconnect: remoteReconnect
            )
            .transition(.opacity)
        }
    }

    private func shouldShowReconnectOverlay(for state: WorkspaceRemoteConnectionState) -> Bool {
        // Terminal panels render the overlay from the AppKit portal
        // (`GhosttySurfaceScrollView.setReconnectOverlay`) because
        // SwiftUI `.overlay {}` cannot paint above the portal-hosted
        // surface. The browser case continues to use the SwiftUI
        // overlay until we move it to AppKit too.
        switch panel.panelType {
        case .browser:
            break
        case .terminal, .markdown, .filePreview, .rightSidebarTool:
            return false
        }
        switch state {
        case .connected:
            return false
        case .connecting, .reconnecting, .error, .disconnected:
            return true
        }
    }

    private var shouldInstallPaneDropTarget: Bool {
        guard isVisibleInUI else { return false }
        switch panel.panelType {
        case .markdown, .filePreview, .rightSidebarTool:
            return true
        case .terminal, .browser:
            return false
        }
    }
}

struct PanelFilePathHeader<TrailingContent: View>: View {
    let iconSystemName: String
    let filePath: String
    let foregroundColor: NSColor
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.clear)
    }
}

struct PanelHeaderIconButton: View {
    let systemName: String
    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelHeaderIconGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PanelHeaderIconGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}
