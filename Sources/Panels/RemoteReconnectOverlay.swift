import SwiftUI

/// Overlay rendered on top of a remote workspace's terminal / browser
/// panel content while the SSH connection is in flight after a drop, or
/// while a best-effort capability (e.g. the browser proxy) is degraded.
///
/// This view is a DUMB renderer: it paints a fully-resolved
/// `RemoteOverlayPresentation` verbatim and has no knowledge of
/// `WorkspaceRemoteConnectionState`. All of the "what should we show"
/// decisions live in `RemoteOverlayPolicy`. The panel content stays
/// mounted so reattachment can restore it without recreating the surface;
/// the overlay communicates "we are working on it" so a network blip
/// doesn't manifest as a silent panel vanish or a hung-looking browser.
struct RemoteReconnectOverlay: View {
    let presentation: RemoteOverlayPresentation

    /// Tick once per second so the elapsed/countdown text re-renders
    /// without us holding a timer per overlay instance.
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch presentation.severity {
            case .blockingDim:
                blockingDim
            case .banner:
                banner
            }
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Blocking dim (whole-workspace transport / provisioning)

    private var blockingDim: some View {
        ZStack {
            // Fully opaque dim — the terminal/web view underneath
            // becomes a faint ghost. The user can tell at a glance
            // this surface is inactive.
            Color.black.opacity(0.94)
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                statusGlyph

                Text(presentation.headline)
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

                // Provisioning (an `.uploading` state) only ever occurs when the
                // remote daemon binary is being (re)installed, which restarts the
                // daemon and discards its in-memory sessions. Warn the user that
                // the runtime update resets active remote sessions, rather than
                // silently dropping their terminals.
                if isUploading {
                    Text(String(
                        localized: "remote.overlay.provisioning.resetWarning",
                        defaultValue: "Updating the remote runtime restarts the remote agent — active remote sessions will be reset."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
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
    }

    // MARK: - Banner (non-blocking capability strip)

    private var banner: some View {
        VStack {
            HStack(spacing: 10) {
                if presentation.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                } else if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if let detail = presentation.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Shared rendering helpers (no state derivation)

    /// The leading glyph for the blocking dim card. Determinate upload bar
    /// when provisioning; circular spinner while a (re)connect is in
    /// flight and there's no error; static warning glyph on a terminal
    /// failure (no retry in flight — the user must act).
    @ViewBuilder
    private var statusGlyph: some View {
        if isUploading {
            ProgressView(value: presentation.provisioning?.progress ?? 0)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 280)
        } else if showsSpinner {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
        } else if presentation.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var isUploading: Bool { presentation.provisioning != nil }

    private var showsSpinner: Bool {
        presentation.showsSpinner && !presentation.isError && presentation.provisioning == nil
    }

    /// "Disconnected for 12 s" — a single running clock. Only shown while a
    /// reconnect is in flight (no running clock on a terminal error —
    /// nothing is being retried).
    private var elapsedText: String? {
        guard !presentation.isError, let r = presentation.reconnect else { return nil }
        let elapsedSec = max(0, Int(now.timeIntervalSince(r.startedAt)))
        return String(
            format: String(
                localized: "remote.overlay.disconnectedFor",
                defaultValue: "Disconnected for %@"
            ),
            locale: .current, formatDuration(elapsedSec)
        )
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
        if let p = presentation.provisioning {
            let sent = ByteCountFormatter.string(fromByteCount: Int64(p.bytesSent), countStyle: .binary)
            let total = ByteCountFormatter.string(fromByteCount: Int64(p.totalBytes), countStyle: .binary)
            let pct = Int((p.progress * 100).rounded())
            let sourceLabel: String
            switch p.source {
            case .localDaemon: sourceLabel = "bundled"
            case .localSelf:   sourceLabel = "ghostty"
            case .github:      sourceLabel = "release"
            }
            return "\(sent) / \(total) (\(pct)%) · \(sourceLabel)"
        }
        if let detail = presentation.detail, !detail.isEmpty { return detail }
        return nil
    }
}
