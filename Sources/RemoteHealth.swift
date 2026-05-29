import Foundation
import GhosttyKit

// MARK: - Remote workspace health model
//
// One value (`RemoteHealth`) is the single source of truth for a remote
// workspace's connection health. It is produced exclusively by one pure
// function (`RemoteHealthReducer.reduce`) from a uniform event vocabulary
// (`RemoteEvent`), and the reducer returns the side effects to run
// (`RemoteEffect`) rather than performing them — so the mapping is
// testable with plain values, runs no I/O, and never mutates state from a
// view body.
//
// The cardinal invariant: `RemoteHealth.primary` (the whole-workspace
// connection state that drives the reconnect overlay, the sidebar, the
// CLI payload, etc.) is projected from the PRIMARY TRANSPORT only.
// Derived best-effort capabilities (the browser proxy, port-forwards, …)
// live in `capabilities` and structurally cannot demote `primary`. That
// is what makes "the browser proxy is down, so the terminal shows
// Reconnecting" impossible by construction — replacing the old, defused
// `preservesSSHTerminalConnection`/`isProxyOnlyRemoteError` guard logic.

/// A best-effort remote feature that rides the one SSH transport. The
/// transport itself is deliberately NOT a capability — only the transport
/// may move whole-workspace state. Adding a future capability (file-sync,
/// LSP tunnel, …) is one case here plus one channel + one `reduce` call.
enum RemoteCapability: Hashable {
    case browserProxy
    case portForward(UUID)
    /// Reverse control channel: an agent/CLI on the REMOTE host can deliver
    /// cmux notifications (`cmux notify` / `notify_target` / `report_*`) to
    /// the LOCAL app. The daemon forwards each framed CLI request received on
    /// a remote-side unix socket back over a `cmux_control` channel; the local
    /// app runs it through the SAME socket dispatcher used for local commands.
    /// Like `browserProxy` this is a derived best-effort capability that rides
    /// the one SSH transport and can never demote `primary`.
    case cmuxControl
}

/// Lifecycle of a single capability, independent of the transport.
enum RemoteCapabilityState: Equatable {
    /// Not started yet / no endpoint available (e.g. proxy tunnel not up).
    case unavailable
    /// (Re)establishing after a drop.
    case connecting
    /// Usable.
    case ready
    /// Up but impaired.
    case degraded
}

/// Typed failure reason, mirroring libghostty's `Ghostty.ConnectionState.Failure.Reason`
/// plus channel-close causes. This is the ONLY place failure semantics are
/// named, and `localizedMessage(target:)` is the single user-facing-string
/// site — replacing localized-substring matching used as control flow.
enum RemoteCapabilityError: Equatable {
    case authFailed
    case timeout
    case transportLost
    case channelClosed
    case helperFailed
    case unknown(String)

    static func from(_ reason: Ghostty.ConnectionState.Failure.Reason) -> RemoteCapabilityError {
        from(reason, message: nil)
    }

    /// Map a ghostty failure reason to a typed error, preserving a non-empty
    /// ghostty-supplied `message` when the reason is `.unknown` (FINDING C).
    /// Known typed reasons keep their specific localized message; an unknown
    /// reason with a non-empty message becomes `.unknown(message)` so the real
    /// failure text isn't replaced by the generic localized fallback.
    static func from(
        _ reason: Ghostty.ConnectionState.Failure.Reason,
        message: String?
    ) -> RemoteCapabilityError {
        switch reason {
        case .authFailed: return .authFailed
        case .timeout: return .timeout
        case .helperFailed: return .helperFailed
        case .unknown:
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .unknown(trimmed)
        }
    }

    /// `true` when retrying with the same configuration can only fail the
    /// same way — the transport should surface a terminal `.error` rather
    /// than an endless "Reconnecting…".
    var isTerminal: Bool {
        switch self {
        case .authFailed: return true
        case .timeout, .transportLost, .channelClosed, .helperFailed, .unknown: return false
        }
    }

    /// The single localized, user-facing message site. `target` is the
    /// "user@host[:port]" display string.
    func localizedMessage(target: String) -> String {
        switch self {
        case .authFailed:
            return String(
                format: String(
                    localized: "remote.failure.authFailed",
                    defaultValue: "Authentication failed for %@ — check your SSH key or password."
                ),
                locale: .current, target
            )
        case .timeout:
            return String(
                format: String(localized: "remote.failure.timeout", defaultValue: "Can't reach %@ yet."),
                locale: .current, target
            )
        case .helperFailed:
            return String(
                format: String(
                    localized: "remote.failure.helperFailed",
                    defaultValue: "Connected to %@, but the remote runtime didn't start."
                ),
                locale: .current, target
            )
        case .transportLost:
            return String(
                format: String(localized: "remote.failure.transportLost", defaultValue: "Lost the connection to %@."),
                locale: .current, target
            )
        case .channelClosed:
            return String(
                format: String(localized: "remote.failure.channelClosed", defaultValue: "The remote channel to %@ closed."),
                locale: .current, target
            )
        case .unknown(let detail):
            if detail.isEmpty {
                return String(
                    format: String(localized: "remote.failure.unknown", defaultValue: "SSH connection to %@ failed."),
                    locale: .current, target
                )
            }
            return detail
        }
    }
}

struct RemoteCapabilityHealth: Equatable {
    var state: RemoteCapabilityState
    var reason: RemoteCapabilityError?
    var detail: String?

    init(state: RemoteCapabilityState, reason: RemoteCapabilityError? = nil, detail: String? = nil) {
        self.state = state
        self.reason = reason
        self.detail = detail
    }

    static let unavailable = RemoteCapabilityHealth(state: .unavailable)
    static let ready = RemoteCapabilityHealth(state: .ready)
}

/// The single source of truth for a remote workspace's connection health.
struct RemoteHealth: Equatable {
    /// Whole-workspace connection state — projected from the PRIMARY
    /// transport ONLY. `capabilities` can never write this.
    var transport: WorkspaceRemoteConnectionState
    /// Typed reason behind a non-connected transport. Drives the
    /// human-readable detail string + the sidebar error entry. nil while
    /// connecting/connected/uploading.
    var transportError: RemoteCapabilityError?
    /// Daemon-binary upload progress (transport stays `.connecting`).
    var provisioning: WorkspaceRemoteProvisioning?
    /// In-flight reconnect snapshot (drives the "Disconnected for Ns" line).
    var reconnect: WorkspaceRemoteReconnectInfo?
    /// While in the future, a late `child_exited` for the old daemon
    /// session is treated as a reconnect artifact, not a real shell exit.
    var graceUntil: Date?
    /// Derived best-effort features riding the one transport.
    var capabilities: [RemoteCapability: RemoteCapabilityHealth]

    init(
        transport: WorkspaceRemoteConnectionState = .disconnected,
        transportError: RemoteCapabilityError? = nil,
        provisioning: WorkspaceRemoteProvisioning? = nil,
        reconnect: WorkspaceRemoteReconnectInfo? = nil,
        graceUntil: Date? = nil,
        capabilities: [RemoteCapability: RemoteCapabilityHealth] = [:]
    ) {
        self.transport = transport
        self.transportError = transportError
        self.provisioning = provisioning
        self.reconnect = reconnect
        self.graceUntil = graceUntil
        self.capabilities = capabilities
    }

    /// The single value every reader observes. Equal to `transport` by
    /// construction; capabilities cannot influence it.
    var primary: WorkspaceRemoteConnectionState { transport }

    /// The localized human-readable detail for the current transport
    /// error, or nil. `target` is the display target.
    func detailMessage(target: String) -> String? {
        transportError?.localizedMessage(target: target)
    }

    static let disconnected = RemoteHealth(transport: .disconnected)
    static let connecting = RemoteHealth(transport: .connecting)
}

// MARK: - Events + effects

/// The one uniform input vocabulary every health source emits into the
/// reducer. Only `.transport` may move `RemoteHealth.transport`.
enum RemoteEvent {
    /// The PRIMARY transport's libghostty connection state changed.
    case transport(Ghostty.ConnectionState)
    /// A derived capability's health changed. Structurally cannot touch
    /// the transport slot.
    case capability(RemoteCapability, RemoteCapabilityHealth)
    /// User asked to (re)connect: reset to `.connecting`.
    case userReconnect
    /// User explicitly disconnected: reset to `.disconnected`.
    case userDisconnect
    /// A local failure that isn't a libghostty transition (e.g. the SSH
    /// integration could not be constructed).
    case localFailure(RemoteCapabilityError)
}

/// Side effects the reducer asks the Workspace to perform. Returned, never
/// run inside the pure reducer — so no I/O or `@Published` mutation ever
/// happens in a view-body-reachable projection.
enum RemoteEffect: Equatable {
    case startProxyTunnel
    case stopProxyTunnel
    /// Start the `cmux_control` reverse channel (remote-originated
    /// notifications). Emitted alongside `.startProxyTunnel` on `.connected`.
    case startControlChannel
    /// Tear the reverse channel down. Emitted alongside `.stopProxyTunnel` on
    /// terminal/disconnect transitions; like the proxy tunnel it is NOT torn
    /// down on transient `.reconnecting`/`.stale` ticks (the channel-close
    /// callback owns degradation so a brief blip doesn't churn it).
    case stopControlChannel
    case requestReconnect
    /// Spawn the deferred first remote terminal (the Workspace still gates
    /// on `pendingInitialRemoteSurface`).
    case spawnDeferredInitialTerminal
    case clearErrorStatus
    case writeErrorStatus(RemoteCapabilityError)
}

// MARK: - The single reducer

enum RemoteHealthReducer {
    /// Grace window opened on `reconnecting -> connected` so libghostty's
    /// late `child_exited` for the dead session doesn't tear panels down.
    static let reconnectGraceInterval: TimeInterval = 5

    /// Pure: `(state, event, now) -> (next state, effects)`. The single
    /// collapse of the old live `handleSSHConnectionState` and the dead
    /// `applyRemoteConnectionStateUpdate`.
    static func reduce(
        _ state: RemoteHealth,
        _ event: RemoteEvent,
        now: Date
    ) -> (RemoteHealth, [RemoteEffect]) {
        switch event {
        case .userReconnect:
            return (RemoteHealth(transport: .connecting), [])
        case .userDisconnect:
            return (RemoteHealth(transport: .disconnected), [.stopProxyTunnel, .stopControlChannel])
        case .localFailure(let err):
            var s = state
            s.transport = .error
            s.transportError = err
            s.provisioning = nil
            s.reconnect = nil
            return (s, [.stopProxyTunnel, .stopControlChannel, .writeErrorStatus(err)])
        case .capability(let cap, let health):
            // Capabilities NEVER touch the transport slot. This is the
            // structural guarantee that a degraded proxy cannot dim a
            // working terminal.
            var s = state
            s.capabilities[cap] = health
            return (s, [])
        case .transport(let cs):
            return reduceTransport(state, cs, now: now)
        }
    }

    private static func reduceTransport(
        _ state: RemoteHealth,
        _ cs: Ghostty.ConnectionState,
        now: Date
    ) -> (RemoteHealth, [RemoteEffect]) {
        var s = state
        var effects: [RemoteEffect] = []
        let wasReconnecting = s.transport == .reconnecting

        switch cs {
        case .connected:
            s.transport = .connected
            s.transportError = nil
            s.provisioning = nil
            s.reconnect = nil
            s.graceUntil = wasReconnecting ? now.addingTimeInterval(reconnectGraceInterval) : nil
            effects.append(.clearErrorStatus)
            effects.append(.startProxyTunnel)
            effects.append(.startControlChannel)
            effects.append(.spawnDeferredInitialTerminal)

        case .connecting:
            s.transport = .connecting
            s.transportError = nil
            s.provisioning = nil

        case .uploading(let upload):
            // Transport is still coming up; stay `.connecting` and let the
            // overlay swap to the upload card off `provisioning`.
            s.transport = .connecting
            s.transportError = nil
            s.provisioning = WorkspaceRemoteProvisioning(
                bytesSent: upload.bytesSent,
                totalBytes: upload.totalBytes,
                source: Self.provisioningSource(from: upload.source)
            )

        case .reconnecting(let info):
            s.transport = .reconnecting
            s.provisioning = nil
            // Preserve the original drop instant across successive
            // `.reconnecting` ticks (one per attempt + one per backoff).
            let startedAt = s.reconnect?.startedAt ?? now.addingTimeInterval(-info.elapsed)
            s.reconnect = WorkspaceRemoteReconnectInfo(
                attempt: info.attempt,
                maxAttempts: info.maxAttempts,
                startedAt: startedAt,
                nextRetryAt: info.nextRetry
            )
            // Deliberately NO `.stopProxyTunnel` here. A transient
            // `.reconnecting` tick (one per attempt + one per backoff) is not
            // a reason to tear the proxy down: doing so churned
            // WKWebView.proxyConfigurations on every blip and raced the
            // documented mux-teardown UAF. The proxy tunnel is now keyed off
            // the actual mux channel close (`RemoteProxyTunnel
            // .onTransportChannelClosed` → `.capability(.browserProxy,
            // .degraded(.channelClosed))` + `stopRemoteProxyTunnel`), so it
            // survives a brief blip and only tears down when the channel
            // genuinely closed at the transport layer.

        case .failed(let failure):
            // FINDING C: `RemoteCapabilityError.from(.unknown)` returns
            // `.unknown("")`, which discards any human-readable ghostty error
            // message and falls back to a generic localized string. When the
            // reason is `.unknown` and ghostty supplied a non-empty message,
            // carry it as `.unknown(message)` so the real failure text reaches
            // the user. Known typed reasons (auth/timeout/helper) keep their
            // specific localized message and their `isTerminal` classification.
            let err = RemoteCapabilityError.from(
                failure.reason,
                message: failure.message
            )
            s.transportError = err
            s.provisioning = nil
            effects.append(.stopProxyTunnel)
            effects.append(.stopControlChannel)
            effects.append(.writeErrorStatus(err))
            if err.isTerminal {
                // Auth rejection: terminal. Surface an actionable error
                // instead of an endless reconnect. Recovery is an explicit
                // user "Reconnect" (which re-opens from scratch).
                s.transport = .error
                s.reconnect = nil
            } else {
                // Transient: libghostty's setup worker owns the retry
                // cadence; we keep the running counter alive and do NOT
                // call requestReconnect (there is no SSH I/O thread to
                // receive it during the initial connect).
                s.transport = .reconnecting
                s.reconnect = s.reconnect ?? Self.seedReconnect(now: now)
            }

        case .disconnected:
            // Never surface a terminal "Disconnected" screen; re-arm a
            // relentless reconnect and wake libghostty's manual-reconnect
            // wait. (Detail is left unchanged from any prior failure.)
            s.transport = .reconnecting
            s.provisioning = nil
            s.reconnect = s.reconnect ?? Self.seedReconnect(now: now)
            effects.append(.stopProxyTunnel)
            effects.append(.stopControlChannel)
            effects.append(.requestReconnect)

        case .passwordRequired, .downloading, .setup:
            // Progress states while the link is still being established.
            // (No interactive password UI exists today; treat as connecting.)
            s.transport = .connecting
            s.provisioning = nil

        case .stale:
            // Recoverable: libghostty is about to reconnect. Like
            // `.reconnecting`, do NOT tear the proxy down here — the
            // channel-close path owns proxy teardown so a brief stale window
            // doesn't churn WKWebView.proxyConfigurations.
            s.transport = .reconnecting
            s.provisioning = nil
            s.reconnect = s.reconnect ?? Self.seedReconnect(now: now)
        }

        return (s, effects)
    }

    private static func seedReconnect(now: Date) -> WorkspaceRemoteReconnectInfo {
        WorkspaceRemoteReconnectInfo(
            attempt: 0,
            maxAttempts: UInt32.max,
            startedAt: now,
            nextRetryAt: nil
        )
    }

    static func provisioningSource(
        from c: Ghostty.ConnectionState.ProvisionSource
    ) -> WorkspaceRemoteProvisioning.Source {
        switch c {
        case .localDaemon: return .localDaemon
        case .localSelf: return .localSelf
        case .github: return .github
        }
    }
}
