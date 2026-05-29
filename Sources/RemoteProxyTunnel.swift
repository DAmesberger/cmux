import Foundation
import Network
import GhosttyKit

/// Local SOCKS5/HTTP CONNECT listener that tunnels each accepted TCP connection
/// through an `SSHChannel<BrowserProxyService>` on the workspace's SSH connection.
///
/// Lifecycle: call `start()` once; it returns the dynamically-assigned local port.
/// Call `stop()` (or let the object deinit) to tear down the listener and all
/// active per-connection pumps.
///
/// Thread-safety: all mutable state is confined to `queue`. `localPort` is
/// written once on `start()` and is safe to read from any thread after that.
@MainActor
final class RemoteProxyTunnel {
    fileprivate static let maxHandshakeBytes = 64 * 1024

    private let connection: Ghostty.SSHConnection
    private var listener: NWListener?
    private var sessions: [UUID: ProxySession] = [:]
    private let queue = DispatchQueue(label: "cmux.remote.proxy.tunnel", qos: .userInitiated)

    /// Fired (once, coalesced) the first time a proxy mux channel closes
    /// because the underlying SSH transport dropped — i.e. a genuine
    /// browser-proxy capability degradation rather than a per-connection
    /// upstream-dial failure or a normal end-of-request close. The owner
    /// (`WorkspaceSSHIntegration` / `Workspace`) uses this to emit a
    /// `.capability(.browserProxy, .degraded(.channelClosed))` event and to
    /// key tunnel teardown on the channel close instead of on every
    /// transient `.reconnecting` transport tick.
    var onTransportChannelClosed: (() -> Void)?
    private var didReportTransportClose = false

    /// The port the listener is bound to. Valid after `start()` returns successfully;
    /// zero before that.
    private(set) var localPort: UInt16 = 0

    init(connection: Ghostty.SSHConnection) {
        self.connection = connection
    }

    deinit {
        // `stop()` is @MainActor-isolated so cannot be called directly from deinit.
        // Capture the listener handle and cancel it on the main actor asynchronously.
        let l = listener
        Task { @MainActor in l?.cancel() }
    }

    /// Bind the listener and start accepting connections. Returns the assigned
    /// local port. Throws if the listener cannot be created.
    @discardableResult
    func start() throws -> UInt16 {
        didReportTransportClose = false
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )

        let newListener = try NWListener(using: params)
        self.listener = newListener

        // Synchronously wait for the listener to become ready so we can
        // return the actual port. NWListener emits .ready quickly on loopback.
        let semaphore = DispatchSemaphore(value: 0)
        var resolvedPort: UInt16 = 0
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                resolvedPort = newListener?.port?.rawValue ?? 0
                semaphore.signal()
            case .failed:
                semaphore.signal()
            default:
                break
            }
            // Keep localPort in sync after the initial start too.
            if case .ready = state, let port = newListener?.port?.rawValue {
                Task { @MainActor in self?.localPort = port }
            }
        }

        newListener.newConnectionHandler = { [weak self] nwConn in
            guard let self else {
                nwConn.cancel()
                return
            }
            Task { @MainActor in
                self.acceptConnection(nwConn)
            }
        }

        newListener.start(queue: queue)
        semaphore.wait()
        localPort = resolvedPort
        return resolvedPort
    }

    func stop() {
        stopSync()
    }

    private func stopSync() {
        listener?.cancel()
        listener = nil
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }

    @MainActor
    private func acceptConnection(_ nwConn: NWConnection) {
        let session = ProxySession(
            connection: nwConn,
            sshConnection: connection,
            queue: queue,
            onClose: { [weak self] id in
                Task { @MainActor in
                    self?.sessions.removeValue(forKey: id)
                }
            },
            onTransportClose: { [weak self] in
                Task { @MainActor in
                    self?.handleTransportChannelClosed()
                }
            }
        )
        sessions[session.id] = session
        session.start()
    }

    /// Coalesce the first transport-level proxy channel close into a single
    /// owner callback. Subsequent closes within the same tunnel lifetime are
    /// ignored; a fresh tunnel (new `start()`) re-arms reporting.
    @MainActor
    private func handleTransportChannelClosed() {
        guard !didReportTransportClose else { return }
        didReportTransportClose = true
        onTransportChannelClosed?()
    }
}

// MARK: - Per-connection session

private final class ProxySession: @unchecked Sendable {
    let id = UUID()

    private let nwConn: NWConnection
    private let sshConnection: Ghostty.SSHConnection
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    /// Fired when this session's channel closes because the underlying SSH
    /// transport dropped (`wasTransport`/`.transport`/`.daemonShutdown`), as
    /// opposed to a normal request end or a per-connection upstream-dial
    /// `.serviceError`. Lets the tunnel owner distinguish "the proxy
    /// capability is degraded" from "this one tab's request ended."
    private let onTransportClose: @Sendable () -> Void

    private enum ProxyProtocol { case undecided, socks5, connect }
    private enum SocksStage { case greeting, request }

    private var proto: ProxyProtocol = .undecided
    private var socksStage: SocksStage = .greeting
    private var handshakeBuffer = Data()
    private var isClosed = false

    // Held strongly so the channel stays alive while the pump tasks run.
    // Stored as an opaque close action so the generic SSHChannel<S> type
    // doesn't need to leak into the class's non-generic storage.
    private var channel: AnyObject?
    private var channelCloseAction: (() -> Void)?

    init(
        connection: NWConnection,
        sshConnection: Ghostty.SSHConnection,
        queue: DispatchQueue,
        onClose: @escaping @Sendable (UUID) -> Void,
        onTransportClose: @escaping @Sendable () -> Void
    ) {
        self.nwConn = connection
        self.sshConnection = sshConnection
        self.queue = queue
        self.onClose = onClose
        self.onTransportClose = onTransportClose
    }

    func start() {
        nwConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.close(reason: "nw failed: \(error)")
            case .cancelled:
                self.close(reason: nil)
            default:
                break
            }
        }
        nwConn.start(queue: queue)
        receiveNext()
    }

    func stop() {
        close(reason: nil)
    }

    private func receiveNext() {
        guard !isClosed else { return }
        nwConn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }

            if let data, !data.isEmpty {
                if self.channel == nil {
                    if self.handshakeBuffer.count + data.count > RemoteProxyTunnel.maxHandshakeBytes {
                        self.close(reason: "handshake overflow")
                        return
                    }
                    self.handshakeBuffer.append(data)
                    self.processHandshake()
                }
                // Once channel is set, the pump task drains nwConn directly.
            }

            if isComplete && self.channel == nil {
                self.close(reason: nil)
                return
            }

            if let error {
                self.close(reason: "receive error: \(error)")
                return
            }

            if self.channel == nil {
                self.receiveNext()
            }
        }
    }

    private func processHandshake() {
        guard !isClosed else { return }
        while channel == nil {
            switch proto {
            case .undecided:
                guard let first = handshakeBuffer.first else { return }
                proto = (first == 0x05) ? .socks5 : .connect
            case .socks5:
                if !processSocks5() { return }
            case .connect:
                if !processHTTPConnect() { return }
            }
        }
    }

    // MARK: SOCKS5

    private func processSocks5() -> Bool {
        switch socksStage {
        case .greeting:
            guard handshakeBuffer.count >= 2 else { return false }
            let nmethods = Int(handshakeBuffer[1])
            let needed = 2 + nmethods
            guard handshakeBuffer.count >= needed else { return false }

            let methods = [UInt8](handshakeBuffer[2..<needed])
            handshakeBuffer = Data(handshakeBuffer.dropFirst(needed))
            socksStage = .request

            guard methods.contains(0x00) else {
                sendAndClose(Data([0x05, 0xFF]))
                return false
            }
            send(Data([0x05, 0x00]))
            return true

        case .request:
            guard let req = parseSocks5Request() else { return false }
            guard req.command == 0x01 else {
                sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                return false
            }
            let pending = handshakeBuffer.count > req.consumed
                ? Data(handshakeBuffer[req.consumed...])
                : Data()
            handshakeBuffer = Data()

            // De-alias the WebKit-routing hostname back to the remote-side
            // loopback name BEFORE handing to BrowserProxyService. The remote
            // host (e.g. NixOS atlas-dev) may not resolve `*.localtest.me` —
            // and even when it does, sending the alias would make the daemon
            // dial a stranger DNS lookup instead of the loopback the user
            // actually wanted. The alias only existed to force WebKit through
            // the proxy in the first place (WebKit bypasses the proxy for
            // raw `localhost`).
            let upstreamHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
                forAliasHost: req.host,
                aliasHost: RemoteLoopbackProxyAlias.aliasHost
            ) ?? req.host

            openChannel(
                host: upstreamHost,
                port: req.port,
                upstreamKind: .socks5Target,
                successReply: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                failureReply: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                pending: pending
            )
            return false
        }
    }

    private struct Socks5Request {
        let host: String
        let port: UInt16
        let command: UInt8
        let consumed: Int
    }

    private func parseSocks5Request() -> Socks5Request? {
        let b = [UInt8](handshakeBuffer)
        guard b.count >= 4, b[0] == 0x05 else { return nil }
        let cmd = b[1]
        var cursor = 4
        let host: String
        switch b[3] {
        case 0x01:
            guard b.count >= cursor + 4 + 2 else { return nil }
            host = b[cursor..<cursor+4].map { String($0) }.joined(separator: ".")
            cursor += 4
        case 0x03:
            guard b.count >= cursor + 1 else { return nil }
            let len = Int(b[cursor]); cursor += 1
            guard b.count >= cursor + len + 2 else { return nil }
            host = String(data: Data(b[cursor..<cursor+len]), encoding: .utf8) ?? ""
            cursor += len
        case 0x04:
            guard b.count >= cursor + 16 + 2 else { return nil }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { p in
                for i in 0..<16 { p[i] = b[cursor + i] }
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let ok = withUnsafePointer(to: &addr) {
                inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
            }
            host = ok != nil ? String(cString: text) : ""
            cursor += 16
        default:
            return nil
        }
        guard b.count >= cursor + 2, !host.isEmpty else { return nil }
        let port = UInt16(b[cursor]) << 8 | UInt16(b[cursor + 1])
        cursor += 2
        guard port > 0 else { return nil }
        return Socks5Request(host: host, port: port, command: cmd, consumed: cursor)
    }

    // MARK: HTTP CONNECT

    private func processHTTPConnect() -> Bool {
        let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let hdrRange = handshakeBuffer.range(of: crlf2) else { return false }

        let headerData = handshakeBuffer[..<hdrRange.upperBound]
        let pending = hdrRange.upperBound < handshakeBuffer.count
            ? Data(handshakeBuffer[hdrRange.upperBound...])
            : Data()
        handshakeBuffer = Data()

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendAndClose(Self.httpResponse(status: "400 Bad Request"))
            return false
        }
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
            sendAndClose(Self.httpResponse(status: "400 Bad Request"))
            return false
        }
        guard let (host, port) = Self.parseAuthority(parts[1]) else {
            sendAndClose(Self.httpResponse(status: "400 Bad Request"))
            return false
        }

        // See SOCKS5 path: de-alias before handing to BrowserProxyService
        // so the remote daemon dials a name it can resolve.
        let upstreamHost = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host,
            aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) ?? host

        openChannel(
            host: upstreamHost,
            port: port,
            upstreamKind: .httpConnectTarget,
            successReply: Self.httpResponse(status: "200 Connection Established", close: false),
            failureReply: Self.httpResponse(status: "502 Bad Gateway", close: true),
            pending: pending
        )
        return false
    }

    private static func parseAuthority(_ authority: String) -> (String, UInt16)? {
        // IPv6 literal: [::1]:port
        if authority.hasPrefix("[") {
            guard let bracket = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<bracket])
            let rest = String(authority[authority.index(after: bracket)...])
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = authority.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    private static func httpResponse(status: String, close: Bool = true) -> Data {
        var resp = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n"
        if close { resp += "Connection: close\r\n" }
        resp += "\r\n"
        return Data(resp.utf8)
    }

    // MARK: Channel open + pump

    private func openChannel(
        host: String,
        port: UInt16,
        upstreamKind: Ghostty.BrowserProxyService.UpstreamKind,
        successReply: Data,
        failureReply: Data,
        pending: Data
    ) {
        guard !isClosed else { return }
        let service = Ghostty.BrowserProxyService(upstreamKind: upstreamKind, host: host, port: port)
        do {
            let ch = try sshConnection.openChannel(service)
            // Retain channel strongly; store a typed close action to avoid
            // casting AnyObject back to the generic SSHChannel<S> later.
            self.channel = ch
            self.channelCloseAction = { ch.close() }

            // Send the success reply immediately (0.5-RTT: don't await .opened).
            send(successReply) { [weak self] in
                guard let self, !self.isClosed else { return }
                if !pending.isEmpty {
                    Task {
                        try? await ch.write(pending)
                    }
                }
                // Start the bidi pump.
                self.startPump(ch)
            }
        } catch {
            sendAndClose(failureReply)
        }
    }

    private func startPump<S: Ghostty.ChannelService>(_ ch: Ghostty.SSHChannel<S>) {
        let nw = nwConn

        // remote → local
        Task { [weak self] in
            for await data in ch.output {
                guard let self, !self.isClosed else { break }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    nw.send(content: data, completion: .contentProcessed { _ in
                        cont.resume()
                    })
                }
            }
            self?.close(reason: nil)
        }

        // channel events: watch for service errors → send reply to local
        Task { [weak self] in
            for await event in ch.events {
                guard let self, !self.isClosed else { break }
                switch event {
                case .closed(let reason, _, let wasTransport):
                    if reason == .serviceError {
                        // Upstream dial failed; send a SOCKS5 refused / HTTP 502 based on proto.
                        switch self.proto {
                        case .socks5:
                            self.sendAndClose(Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                        default:
                            self.sendAndClose(Self.httpResponse(status: "502 Bad Gateway", close: true))
                        }
                    } else {
                        // A transport-level close (the SSH mux dropped, the
                        // daemon shut down, or libghostty flagged the close as
                        // transport-caused) means the whole browser-proxy
                        // capability is degraded — not just this one request.
                        // Surface it to the owner so it can mark the capability
                        // degraded and tear the tunnel down here, instead of on
                        // every transient transport `.reconnecting` tick.
                        if wasTransport || reason == .transport || reason == .daemonShutdown {
                            self.onTransportClose()
                        }
                        self.close(reason: nil)
                    }
                default:
                    break
                }
            }
        }

        // local → remote
        Task { [weak self] in
            while let self, !self.isClosed {
                let data = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                    nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            cont.resume(returning: data)
                        } else if isComplete || error != nil {
                            cont.resume(returning: nil)
                        } else {
                            cont.resume(returning: Data())
                        }
                    }
                }
                guard let data else {
                    self.close(reason: nil)
                    break
                }
                if data.isEmpty { continue }
                do {
                    try await ch.write(data)
                } catch {
                    self.close(reason: "channel write error: \(error)")
                    break
                }
            }
        }
    }

    // MARK: Send helpers

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        nwConn.send(content: data, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func sendAndClose(_ data: Data) {
        nwConn.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close(reason: nil)
        })
    }

    private func close(reason: String?) {
        guard !isClosed else { return }
        isClosed = true
#if DEBUG
        if let reason { cmuxDebugLog("remote.proxy.session[\(id.uuidString.prefix(5))].close \(reason)") }
#endif
        nwConn.cancel()
        channelCloseAction?()
        channel = nil
        channelCloseAction = nil
        onClose(id)
    }
}
