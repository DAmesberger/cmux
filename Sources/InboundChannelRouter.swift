import Foundation
import GhosttyKit

// MARK: - InboundChannelHandler

/// A consumer of daemon-originated inbound channels. The router offers each
/// `Ghostty.InboundChannel` to registered handlers in priority order; the
/// first handler that claims it (by calling `accept(using:)` or `reject()`)
/// stops the offer chain.
///
/// Contract: `tryHandle` MUST return `.claimed` if and only if it consumed the
/// inbound (accepted or rejected it). Returning `.passed` means "not mine,
/// leave it for the next handler" and the handler MUST NOT have touched the
/// inbound's one-shot accept/reject claim.
@MainActor
protocol InboundChannelHandler: AnyObject {
    /// Offer one inbound channel to this handler.
    func tryHandle(_ inbound: Ghostty.InboundChannel) -> InboundChannelDisposition
}

/// Result of offering an inbound channel to a handler.
enum InboundChannelDisposition {
    /// The handler consumed the inbound (called `accept`/`reject`). Stop.
    case claimed
    /// Not for this handler. Offer it to the next one.
    case passed
}

// MARK: - InboundChannelRouter

/// Single per-connection demultiplexer for `Ghostty.SSHConnection.inboundChannels`.
///
/// Background: the macOS SDK emits exactly ONE `AsyncStream<InboundChannel>`
/// per `SSHConnection`. Two concurrent `for await` loops over that single
/// stream SPLIT elements between iterators (each yielded element goes to
/// whichever iterator is currently suspended on `next()`), so a given inbound
/// is delivered to only ONE consumer. Before this router, `PortForwardHandle`
/// and `RemoteControlChannel` each ran their own loop, so routing between them
/// was nondeterministic and a port-forward accept could be delivered to the
/// control-channel loop (and dropped) or vice versa.
///
/// This router replaces those competing loops with ONE loop, owned by
/// `WorkspaceSSHIntegration` (which owns the connection). It reads each
/// `InboundChannel` exactly once and offers it to registered handlers in
/// priority order, dispatching by `(serviceID, params-prefix)`:
///   * `cmuxctl1`-tagged custom channels -> `RemoteControlChannel`
///   * other custom channels (16-byte UUID-prefixed) -> the active
///     `PortForwardHandle`s
/// Any inbound no handler claims is rejected, so nothing is leaked or split.
///
/// Handlers are held weakly and in registration order. Each handler keeps the
/// existing one-shot `accept(using:)`/`reject()` claim semantics — the router
/// never touches the inbound itself except to reject a fully unclaimed one.
@MainActor
final class InboundChannelRouter {
    private let connection: Ghostty.SSHConnection
    private var loopTask: Task<Void, Never>?
    private var isStopped = false

    /// Weak handler box so a torn-down handle (e.g. a closed `PortForwardHandle`)
    /// is skipped and pruned rather than keeping it alive or crashing.
    private struct WeakHandler {
        weak var handler: InboundChannelHandler?
    }

    /// Registered handlers, offered in order. Control channel registers ahead
    /// of port forwards so the cheap 8-byte tag check runs first, but ordering
    /// is not load-bearing for correctness because each handler's guard is
    /// mutually exclusive on the params discriminator.
    private var handlers: [WeakHandler] = []

    init(connection: Ghostty.SSHConnection) {
        self.connection = connection
    }

    deinit {
        loopTask?.cancel()
    }

    /// Register a handler. Idempotent: a handler already registered is not
    /// added twice. Starts the single inbound loop lazily on first register.
    func register(_ handler: InboundChannelHandler) {
        guard !isStopped else { return }
        pruneReleased()
        if handlers.contains(where: { $0.handler === handler }) { return }
        handlers.append(WeakHandler(handler: handler))
        startIfNeeded()
    }

    /// Unregister a handler (e.g. when a `PortForwardHandle` closes or the
    /// `RemoteControlChannel` stops). Safe to call for a handler that was
    /// never registered.
    func unregister(_ handler: InboundChannelHandler) {
        handlers.removeAll { $0.handler === handler || $0.handler == nil }
    }

    /// Stop the loop and drop all handlers. Called on connection teardown.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        loopTask?.cancel()
        loopTask = nil
        handlers.removeAll()
    }

    private func startIfNeeded() {
        guard loopTask == nil, !isStopped else { return }
        let conn = connection
        loopTask = Task { [weak self] in
            for await inbound in conn.inboundChannels {
                guard let self else {
                    // Router gone: nothing can claim this inbound. Reject so
                    // the daemon learns the channel was not accepted.
                    inbound.reject()
                    continue
                }
                self.dispatch(inbound)
            }
        }
    }

    /// Offer one inbound channel to each live handler in order. The first that
    /// claims it wins. If none claims it, reject it so the mux is unblocked and
    /// nothing leaks.
    private func dispatch(_ inbound: Ghostty.InboundChannel) {
        pruneReleased()
        for box in handlers {
            guard let handler = box.handler else { continue }
            if case .claimed = handler.tryHandle(inbound) {
                return
            }
        }
        // No handler recognized it. Reject so the daemon isn't left waiting.
        inbound.reject()
    }

    private func pruneReleased() {
        handlers.removeAll { $0.handler == nil }
    }
}
