import XCTest
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure tests for the single remote-health reducer + overlay policy. No
/// live SSH, no Workspace construction — everything is value-level, which
/// is the whole point of extracting `RemoteHealthReducer.reduce` and
/// `RemoteOverlayPolicy.presentation` as pure functions.
final class RemoteHealthReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let target = "dev@atlas-dev"

    private func connectedHealth() -> RemoteHealth {
        let (h, _) = RemoteHealthReducer.reduce(.connecting, .transport(.connected), now: t0)
        return h
    }

    // MARK: - The bug fix, expressed at the value level

    func testProxyOnlyDegradationKeepsTransportConnected() {
        let connected = connectedHealth()
        XCTAssertEqual(connected.primary, .connected)

        // A degraded browser proxy must NOT move the transport.
        let (next, effects) = RemoteHealthReducer.reduce(
            connected,
            .capability(.browserProxy, RemoteCapabilityHealth(state: .connecting, reason: .transportLost)),
            now: t0
        )
        XCTAssertEqual(next.primary, .connected, "a capability must never demote the transport")
        XCTAssertTrue(effects.isEmpty, "a capability event produces no transport effects")

        // The terminal host shows nothing; the browser host shows a banner.
        XCTAssertNil(
            RemoteOverlayPolicy.presentation(for: next, host: .terminal, target: target),
            "a proxy-only degradation must never dim the terminal"
        )
        let browser = RemoteOverlayPolicy.presentation(for: next, host: .browser, target: target)
        XCTAssertEqual(browser?.severity, .banner)
        XCTAssertEqual(browser?.scope, .capability(.browserProxy))
    }

    func testBrowserProxyConnectingHintDoesNotMarkProxyReadyOrMoveTransport() {
        // FINDING G: when the C-API SSH connection reaches `.connected`,
        // `Workspace.proxyCapabilityHealth` now maps it to a NON-authoritative
        // `.browserProxy` hint of `state: .connecting` (transport up, SOCKS
        // tunnel not yet confirmed) — never `.ready`. Only the
        // `RemoteProxyTunnel` bind owns `.ready`. This is the event the C-API
        // path dispatches; assert that feeding it into the reducer (a) records
        // the capability as `.connecting`, never `.ready`, and (b) cannot move
        // the transport off `.connected`.
        let connected = connectedHealth()
        XCTAssertEqual(connected.primary, .connected)

        let (next, effects) = RemoteHealthReducer.reduce(
            connected,
            .capability(.browserProxy, RemoteCapabilityHealth(state: .connecting)),
            now: t0
        )
        XCTAssertEqual(next.primary, .connected, "the proxy hint must never demote the transport")
        XCTAssertTrue(effects.isEmpty, "a capability event produces no transport effects")
        XCTAssertEqual(
            next.capabilities[.browserProxy]?.state, .connecting,
            "the C-API .connected hint records .connecting, never .ready")
        XCTAssertNotEqual(
            next.capabilities[.browserProxy]?.state, .ready,
            "FINDING G: transport-up alone must not assert the proxy is ready")

        // The authoritative `.ready` arrives later from the tunnel bind and
        // overwrites the hint; transport still does not move.
        let (ready, readyEffects) = RemoteHealthReducer.reduce(
            next, .capability(.browserProxy, .ready), now: t0)
        XCTAssertEqual(ready.primary, .connected)
        XCTAssertTrue(readyEffects.isEmpty)
        XCTAssertEqual(ready.capabilities[.browserProxy]?.state, .ready)
    }

    // MARK: - Relentless reconnect matrix

    func testAuthFailureIsTerminalErrorWithNoReconnect() {
        let (next, effects) = RemoteHealthReducer.reduce(
            .connecting, .transport(.failed(.init(reason: .authFailed, message: nil))), now: t0)
        XCTAssertEqual(next.primary, .error)
        XCTAssertNil(next.reconnect)
        XCTAssertFalse(effects.contains(.requestReconnect), "auth failure must not retry")
        XCTAssertTrue(effects.contains(.stopProxyTunnel))
        XCTAssertTrue(effects.contains(.writeErrorStatus(.authFailed)))
    }

    func testTransientFailureReconnectsWithoutRequestReconnect() {
        for reason in [Ghostty.ConnectionState.Failure.Reason.timeout, .helperFailed, .unknown] {
            let (next, effects) = RemoteHealthReducer.reduce(
                .connecting, .transport(.failed(.init(reason: reason, message: nil))), now: t0)
            XCTAssertEqual(next.primary, .reconnecting, "reason \(reason) should be transient")
            XCTAssertNotNil(next.reconnect, "transient failure seeds the reconnect counter")
            XCTAssertFalse(
                effects.contains(.requestReconnect),
                "initial-connect retry is driven by libghostty's worker, not requestReconnect")
        }
    }

    func testDisconnectedReArmsAndRequestsReconnect() {
        let (next, effects) = RemoteHealthReducer.reduce(
            connectedHealth(), .transport(.disconnected(.init(attemptsMade: 3, reason: .exhausted))), now: t0)
        XCTAssertEqual(next.primary, .reconnecting)
        XCTAssertNotNil(next.reconnect)
        XCTAssertTrue(effects.contains(.requestReconnect))
        XCTAssertTrue(effects.contains(.stopProxyTunnel))
    }

    // MARK: - Reconnect grace window edge

    func testGraceWindowOpensOnlyOnReconnectingToConnected() {
        let (reconnecting, _) = RemoteHealthReducer.reduce(
            .connecting,
            .transport(.reconnecting(.init(attempt: 1, maxAttempts: .max, elapsed: 0, nextRetry: nil))),
            now: t0)
        let (recovered, _) = RemoteHealthReducer.reduce(reconnecting, .transport(.connected), now: t0)
        XCTAssertEqual(recovered.graceUntil, t0.addingTimeInterval(RemoteHealthReducer.reconnectGraceInterval))

        // connected -> connected (no prior reconnect) opens no grace window.
        let (steady, _) = RemoteHealthReducer.reduce(connectedHealth(), .transport(.connected), now: t0)
        XCTAssertNil(steady.graceUntil)
    }

    // MARK: - Previously-dropped ConnectionState cases now map explicitly

    func testProgressStatesMapToConnecting() {
        for cs in [Ghostty.ConnectionState.downloading, .setup] {
            let (next, _) = RemoteHealthReducer.reduce(.disconnected, .transport(cs), now: t0)
            XCTAssertEqual(next.primary, .connecting, "\(cs) should be a connecting/progress state")
        }
    }

    func testStaleMapsToReconnectingWithoutStoppingProxy() {
        // FINDING E: Stage 5 deliberately made `.stale` (like `.reconnecting`)
        // emit NO proxy/control teardown so a transient stale window does not
        // churn WKWebView.proxyConfigurations or race the mux-teardown UAF. The
        // proxy tunnel is keyed off the actual mux channel close, not a stale
        // tick. Assert the CURRENT correct behavior: transport moves to
        // `.reconnecting`, the reconnect counter is seeded, and NO stop effect
        // is emitted.
        let (next, effects) = RemoteHealthReducer.reduce(connectedHealth(), .transport(.stale), now: t0)
        XCTAssertEqual(next.primary, .reconnecting)
        XCTAssertNotNil(next.reconnect, "a stale tick seeds the reconnect counter")
        XCTAssertFalse(
            effects.contains(.stopProxyTunnel),
            "a stale tick must not tear the proxy down — the channel-close path owns proxy teardown")
        XCTAssertFalse(
            effects.contains(.stopControlChannel),
            "a stale tick must not churn the reverse control channel")
    }

    func testReconnectingTickDoesNotStopProxy() {
        // The sibling case to `.stale`: a transient `.reconnecting` tick (one
        // per attempt + one per backoff) is not a reason to tear the proxy
        // down. Only a genuine `.disconnected`/`.failed` transition stops it.
        let (next, effects) = RemoteHealthReducer.reduce(
            connectedHealth(),
            .transport(.reconnecting(.init(attempt: 1, maxAttempts: .max, elapsed: 0, nextRetry: nil))),
            now: t0)
        XCTAssertEqual(next.primary, .reconnecting)
        XCTAssertFalse(
            effects.contains(.stopProxyTunnel),
            "a transient reconnect tick must not tear the proxy down")
        XCTAssertFalse(
            effects.contains(.stopControlChannel),
            "a transient reconnect tick must not churn the reverse control channel")
    }

    // MARK: - Lifecycle events

    func testUserReconnectResetsToConnecting() {
        var dirty = connectedHealth()
        dirty.capabilities[.browserProxy] = .ready
        let (next, effects) = RemoteHealthReducer.reduce(dirty, .userReconnect, now: t0)
        XCTAssertEqual(next.primary, .connecting)
        XCTAssertTrue(next.capabilities.isEmpty)
        XCTAssertNil(next.transportError)
        XCTAssertTrue(effects.isEmpty)
    }

    func testUserDisconnectResetsAndStopsProxy() {
        let (next, effects) = RemoteHealthReducer.reduce(connectedHealth(), .userDisconnect, now: t0)
        XCTAssertEqual(next.primary, .disconnected)
        XCTAssertTrue(effects.contains(.stopProxyTunnel))
    }

    func testLocalFailureIsTerminalError() {
        let (next, effects) = RemoteHealthReducer.reduce(.connecting, .localFailure(.unknown("boom")), now: t0)
        XCTAssertEqual(next.primary, .error)
        XCTAssertEqual(next.transportError, .unknown("boom"))
        XCTAssertTrue(effects.contains(.writeErrorStatus(.unknown("boom"))))
    }

    // MARK: - Connected clears prior error + starts proxy + spawns terminal

    func testConnectedClearsErrorAndDrivesSideEffects() {
        let (failed, _) = RemoteHealthReducer.reduce(
            .connecting, .transport(.failed(.init(reason: .timeout, message: nil))), now: t0)
        XCTAssertNotNil(failed.transportError)
        let (connected, effects) = RemoteHealthReducer.reduce(failed, .transport(.connected), now: t0)
        XCTAssertEqual(connected.primary, .connected)
        XCTAssertNil(connected.transportError)
        XCTAssertNil(connected.reconnect)
        XCTAssertTrue(effects.contains(.clearErrorStatus))
        XCTAssertTrue(effects.contains(.startProxyTunnel))
        XCTAssertTrue(effects.contains(.spawnDeferredInitialTerminal))
    }

    // MARK: - Reverse control channel (cmux_control) effects + capability

    func testConnectedStartsControlChannelAlongsideProxy() {
        let (connected, effects) = RemoteHealthReducer.reduce(.connecting, .transport(.connected), now: t0)
        XCTAssertEqual(connected.primary, .connected)
        XCTAssertTrue(effects.contains(.startControlChannel), "connected must start the reverse control channel")
        XCTAssertTrue(effects.contains(.startProxyTunnel), "connected still starts the proxy tunnel")
    }

    func testUserDisconnectStopsControlChannel() {
        let (next, effects) = RemoteHealthReducer.reduce(connectedHealth(), .userDisconnect, now: t0)
        XCTAssertEqual(next.primary, .disconnected)
        XCTAssertTrue(effects.contains(.stopControlChannel), "user disconnect tears the reverse channel down")
        XCTAssertTrue(effects.contains(.stopProxyTunnel))
    }

    func testTransportTeardownStopsControlChannel() {
        // Both terminal failures and a relentless-reconnect disconnect tear the
        // reverse channel down (mirroring the proxy tunnel); a transient
        // `.reconnecting`/`.stale` tick deliberately does NOT.
        let (afterFailure, failEffects) = RemoteHealthReducer.reduce(
            connectedHealth(), .transport(.failed(.init(reason: .timeout, message: nil))), now: t0)
        XCTAssertTrue(failEffects.contains(.stopControlChannel), "a transport failure stops the reverse channel")
        XCTAssertEqual(afterFailure.primary, .reconnecting)

        let (_, disconnectEffects) = RemoteHealthReducer.reduce(
            connectedHealth(), .transport(.disconnected(.init(attemptsMade: 1, reason: .exhausted))), now: t0)
        XCTAssertTrue(disconnectEffects.contains(.stopControlChannel), "a disconnect stops the reverse channel")

        let (_, localFailureEffects) = RemoteHealthReducer.reduce(
            connectedHealth(), .localFailure(.unknown("boom")), now: t0)
        XCTAssertTrue(localFailureEffects.contains(.stopControlChannel), "a local failure stops the reverse channel")

        // Transient ticks must NOT churn the channel.
        let (_, reconnectingEffects) = RemoteHealthReducer.reduce(
            connectedHealth(),
            .transport(.reconnecting(.init(attempt: 1, maxAttempts: .max, elapsed: 0, nextRetry: nil))),
            now: t0)
        XCTAssertFalse(reconnectingEffects.contains(.stopControlChannel), "a transient reconnect tick must not churn the channel")
        let (_, staleEffects) = RemoteHealthReducer.reduce(connectedHealth(), .transport(.stale), now: t0)
        XCTAssertFalse(staleEffects.contains(.stopControlChannel), "a stale tick must not churn the channel")
    }

    func testCmuxControlCapabilityNeverMovesTransportOrEmitsEffects() {
        let connected = connectedHealth()
        XCTAssertEqual(connected.primary, .connected)

        // A reverse-control-channel capability event is a derived capability,
        // exactly like `.browserProxy`: it records health but can never move
        // the transport and produces no transport effects.
        let (next, effects) = RemoteHealthReducer.reduce(
            connected,
            .capability(.cmuxControl, RemoteCapabilityHealth(state: .degraded, reason: .channelClosed)),
            now: t0
        )
        XCTAssertEqual(next.primary, .connected, "a cmux_control capability must never demote the transport")
        XCTAssertTrue(effects.isEmpty, "a capability event produces no transport effects")
        XCTAssertEqual(next.capabilities[.cmuxControl]?.state, .degraded)

        // Bringing it back to ready likewise leaves the transport untouched.
        let (ready, readyEffects) = RemoteHealthReducer.reduce(next, .capability(.cmuxControl, .ready), now: t0)
        XCTAssertEqual(ready.primary, .connected)
        XCTAssertTrue(readyEffects.isEmpty)
        XCTAssertEqual(ready.capabilities[.cmuxControl]?.state, .ready)
    }

    // MARK: - Overlay policy

    func testProvisioningShowsUploadCardOnBothHosts() {
        var h = connectedHealth()
        h.provisioning = WorkspaceRemoteProvisioning(bytesSent: 1, totalBytes: 10, source: .localDaemon)
        for host in [RemoteOverlayHost.terminal, .browser] {
            let p = RemoteOverlayPolicy.presentation(for: h, host: host, target: target)
            XCTAssertEqual(p?.severity, .blockingDim, "upload card must show on \(host)")
            XCTAssertNotNil(p?.provisioning)
        }
    }

    func testConnectedHealthyShowsNothing() {
        let h = connectedHealth()
        XCTAssertNil(RemoteOverlayPolicy.presentation(for: h, host: .terminal, target: target))
        XCTAssertNil(RemoteOverlayPolicy.presentation(for: h, host: .browser, target: target))
    }

    func testTransportDownDimsBothHosts() {
        let (reconnecting, _) = RemoteHealthReducer.reduce(
            .connecting,
            .transport(.reconnecting(.init(attempt: 2, maxAttempts: .max, elapsed: 1, nextRetry: nil))),
            now: t0)
        for host in [RemoteOverlayHost.terminal, .browser] {
            let p = RemoteOverlayPolicy.presentation(for: reconnecting, host: host, target: target)
            XCTAssertEqual(p?.severity, .blockingDim)
            XCTAssertEqual(p?.scope, .wholeWorkspace)
            XCTAssertFalse(p?.isError ?? true)
        }
    }

    func testAuthErrorOverlayIsActionableNonSpinner() {
        let (errored, _) = RemoteHealthReducer.reduce(
            .connecting, .transport(.failed(.init(reason: .authFailed, message: nil))), now: t0)
        let p = RemoteOverlayPolicy.presentation(for: errored, host: .terminal, target: target)
        XCTAssertEqual(p?.severity, .blockingDim)
        XCTAssertTrue(p?.isError ?? false)
        XCTAssertFalse(p?.showsSpinner ?? true)
        XCTAssertNotNil(p?.detail)
    }
}
