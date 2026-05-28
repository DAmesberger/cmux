import SwiftUI

/// Overlay rendered on top of a remote workspace's terminal / browser
/// panel content while the SSH connection is in flight after a drop.
/// The panel content stays mounted so reattachment can restore it
/// without recreating the surface; the overlay communicates "we are
/// working on it" so a network blip doesn't manifest as a silent
/// panel vanish or a hung-looking browser.
struct RemoteReconnectOverlay: View {
    let state: WorkspaceRemoteConnectionState
    let target: String?
    let detail: String?
    /// When non-nil the overlay swaps its headline to "Uploading
    /// runtime…" and renders a determinate progress bar.
    let provisioning: WorkspaceRemoteProvisioning?
    /// When non-nil the overlay shows elapsed time since the drop +
    /// attempt counter so the user can tell how long they've been
    /// disconnected.
    let reconnect: WorkspaceRemoteReconnectInfo?

    /// Tick once per second so the elapsed/countdown text re-renders
    /// without us holding a timer per overlay instance.
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Fully opaque dim — the terminal/web view underneath
            // becomes a faint ghost. The user can tell at a glance
            // this surface is inactive.
            Color.black.opacity(0.94)
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                if isUploading {
                    ProgressView(value: provisioning?.progress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 280)
                } else if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                }

                Text(headlineText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                if let elapsedText {
                    Text(elapsedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }

                if let secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.65), radius: 22, x: 0, y: 8)
            )
        }
        .onReceive(tick) { now = $0 }
    }

    private var isUploading: Bool { provisioning != nil }

    private var showsSpinner: Bool {
        switch state {
        case .connecting, .reconnecting, .error, .disconnected: return true
        case .connected: return false
        }
    }

    private var headlineText: String {
        if isUploading {
            return String(
                localized: "remote.overlay.uploading",
                defaultValue: "Uploading runtime…"
            )
        }
        // Per product direction: never display a terminal "Disconnected" /
        // "Connection lost" headline. The SSH integration is configured for
        // relentless reconnect, so the user-visible story is always either
        // "we are establishing the link" (initial connect) or "we are
        // retrying after a drop." `.error` and `.disconnected` are folded
        // into the reconnect branch.
        switch state {
        case .connecting:
            return String(
                localized: "remote.overlay.connecting",
                defaultValue: "Connecting…"
            )
        case .reconnecting, .error, .disconnected:
            return String(
                localized: "remote.overlay.reconnecting",
                defaultValue: "Reconnecting…"
            )
        case .connected:
            return ""
        }
    }

    /// "Disconnected for 12 s" — a single running clock. The attempt
    /// counter was removed because libghostty's reconnect loop cycles
    /// the number on every retry and that produces visual noise
    /// without communicating anything actionable to the user.
    private var elapsedText: String? {
        guard let r = reconnect else { return nil }
        let elapsedSec = max(0, Int(now.timeIntervalSince(r.startedAt)))
        return "Disconnected for \(formatDuration(elapsedSec))"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        if m < 60 { return "\(m)m \(s)s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h \(mm)m"
    }

    private var secondaryText: String? {
        if let p = provisioning {
            let sent = ByteCountFormatter.string(fromByteCount: Int64(p.bytesSent), countStyle: .binary)
            let total = ByteCountFormatter.string(fromByteCount: Int64(p.totalBytes), countStyle: .binary)
            let pct = Int((p.progress * 100).rounded())
            let sourceLabel: String
            switch p.source {
            case .localDaemon: sourceLabel = "bundled"
            case .localSelf:   sourceLabel = "ghostty"
            case .github:      sourceLabel = "release"
            }
            if let target, !target.isEmpty {
                return "\(target) — \(sent) / \(total) (\(pct)%) · \(sourceLabel)"
            }
            return "\(sent) / \(total) (\(pct)%) · \(sourceLabel)"
        }
        if let detail, !detail.isEmpty { return detail }
        if let target, !target.isEmpty { return target }
        return nil
    }
}
