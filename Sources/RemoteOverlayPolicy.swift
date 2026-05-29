import Foundation

// MARK: - Remote overlay policy
//
// One pure function decides what (if anything) the remote-connection
// overlay shows, for either host. It replaces the two drifted `shouldShow`
// gates (the SwiftUI browser gate in `PanelContentView` and the AppKit
// terminal gate in `GhosttyTerminalView`) and the three scattered
// `WorkspaceRemoteConnectionState -> String` switches.
//
// The decisive rule: the full-screen blocking dim is keyed to the PRIMARY
// transport ONLY. A degraded capability (e.g. the browser proxy) can never
// produce a blocking dim — at most a lightweight, non-blocking banner in
// the browser host, leaving the terminal completely untouched.

/// Which host is rendering. Terminals paint via an AppKit portal; browsers
/// via a SwiftUI `.overlay`. Host-awareness lets a capability-only
/// degradation surface a browser banner while the terminal shows nothing.
enum RemoteOverlayHost: Equatable {
    case terminal
    case browser
}

/// The fully-resolved presentation. The renderer is dumb: it paints these
/// values verbatim, with no knowledge of `WorkspaceRemoteConnectionState`.
struct RemoteOverlayPresentation: Equatable {
    enum Severity: Equatable {
        /// Full-screen opaque dim — the workspace is not usable (or is
        /// provisioning). Mounted by both hosts.
        case blockingDim
        /// Lightweight non-blocking strip — a capability is degraded but
        /// the workspace (terminal) is fully usable.
        case banner
    }

    var severity: Severity
    var scope: RemoteOverlayScope
    var headline: String
    var detail: String?
    var showsSpinner: Bool
    var isError: Bool
    var provisioning: WorkspaceRemoteProvisioning?
    var reconnect: WorkspaceRemoteReconnectInfo?
}

enum RemoteOverlayScope: Equatable {
    case wholeWorkspace
    case capability(RemoteCapability)
}

enum RemoteOverlayPolicy {
    /// The single overlay decision. Returns nil to render nothing.
    /// `target` is the display target used for message text.
    static func presentation(
        for health: RemoteHealth,
        host: RemoteOverlayHost,
        target: String?
    ) -> RemoteOverlayPresentation? {
        let target = target ?? ""

        // 1) The PRIMARY transport governs the full-screen dim for BOTH
        //    hosts. (Provisioning is folded in here so the upload card
        //    shows on both hosts — fixing the old browser-only drift.)
        if let dim = transportPresentation(for: health, target: target) {
            return dim
        }

        // 2) Transport is connected. Only the BROWSER host surfaces a
        //    degraded browser-proxy capability, and only as a non-blocking
        //    banner. The terminal returns nil here — the bug fix.
        if host == .browser, let banner = browserProxyBanner(for: health) {
            return banner
        }

        return nil
    }

    // MARK: Transport (whole-workspace) dim

    private static func transportPresentation(
        for health: RemoteHealth,
        target: String
    ) -> RemoteOverlayPresentation? {
        // Provisioning takes precedence even though the transport may
        // already be `.connecting`/`.connected` for the SSH layer.
        if let prov = health.provisioning {
            return RemoteOverlayPresentation(
                severity: .blockingDim,
                scope: .wholeWorkspace,
                headline: Strings.uploading,
                detail: nil,
                showsSpinner: false,
                isError: false,
                provisioning: prov,
                reconnect: nil
            )
        }

        switch health.transport {
        case .connected:
            return nil
        case .connecting:
            return RemoteOverlayPresentation(
                severity: .blockingDim,
                scope: .wholeWorkspace,
                headline: Strings.connecting,
                detail: health.detailMessage(target: target),
                showsSpinner: true,
                isError: false,
                provisioning: nil,
                reconnect: health.reconnect
            )
        case .reconnecting, .disconnected:
            return RemoteOverlayPresentation(
                severity: .blockingDim,
                scope: .wholeWorkspace,
                headline: Strings.reconnecting,
                detail: health.detailMessage(target: target),
                showsSpinner: true,
                isError: false,
                provisioning: nil,
                reconnect: health.reconnect
            )
        case .error:
            return RemoteOverlayPresentation(
                severity: .blockingDim,
                scope: .wholeWorkspace,
                headline: Strings.failed,
                detail: health.detailMessage(target: target),
                showsSpinner: false,
                isError: true,
                provisioning: nil,
                reconnect: nil
            )
        }
    }

    // MARK: Capability banner (browser only)

    private static func browserProxyBanner(for health: RemoteHealth) -> RemoteOverlayPresentation? {
        guard let proxy = health.capabilities[.browserProxy] else { return nil }
        switch proxy.state {
        case .ready, .unavailable:
            // `unavailable` = not started yet; the browser just waits
            // (navigations are queued). No banner.
            return nil
        case .connecting, .degraded:
            return RemoteOverlayPresentation(
                severity: .banner,
                scope: .capability(.browserProxy),
                headline: Strings.proxyBanner,
                detail: proxy.detail,
                showsSpinner: proxy.state == .connecting,
                isError: false,
                provisioning: nil,
                reconnect: nil
            )
        }
    }

    // MARK: Localized headline strings (single site)

    enum Strings {
        static var connecting: String {
            String(localized: "remote.overlay.connecting", defaultValue: "Connecting…")
        }
        static var reconnecting: String {
            String(localized: "remote.overlay.reconnecting", defaultValue: "Reconnecting…")
        }
        static var failed: String {
            String(localized: "remote.overlay.failed", defaultValue: "SSH connection failed")
        }
        static var uploading: String {
            String(localized: "remote.overlay.uploading", defaultValue: "Uploading runtime…")
        }
        static var proxyBanner: String {
            String(
                localized: "remote.overlay.proxyBanner",
                defaultValue: "Browser proxy reconnecting — terminal unaffected"
            )
        }
    }
}
