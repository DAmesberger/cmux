import Darwin
import Foundation

/// PTY-relay glue that bridges a Ghostty terminal surface to a remote SSH
/// session over `SessionBridge`.
///
/// ### Why a PTY relay?
///
/// Ghostty's embedded surface always owns its own forkpty()-spawned child.
/// Libghostty does not expose a "feed bytes directly into the parser" API,
/// so the cheapest way to make a Ghostty surface display bytes that arrive
/// from somewhere other than a local shell is to:
///
/// 1. `openpty()` a PTY pair owned by cmux (`masterFd`, `slaveFd`).
/// 2. Ask Ghostty to spawn a tiny shell command in *its own* PTY that, via
///    file redirection, pipes our PTY slave to/from its stdin/stdout. The
///    bytes that Ghostty's PTY master sees (and the parser ultimately
///    processes) are then exactly the bytes we write to `masterFd`, and
///    every keystroke Ghostty forwards to its child appears on `masterFd`
///    as readable data.
/// 3. Pump those bytes through a `SessionBridge`:
///    - master-fd output  →  `bridge.send(...)`
///    - `bridge.onOutput` →  `write(masterFd, ...)`
///
/// Resize is delivered via `TIOCSWINSZ` on the master fd so the slave-side
/// PTY mirrors the Ghostty viewport (the daemon side is told via
/// `bridge.resize(...)`).
///
/// ### Lifetime
///
/// The relay is created when a remote-workspace terminal surface is about
/// to be constructed, the PTY is allocated and the surface command is
/// derived, then the relay is `start(bridge:)`ed once the workspace has
/// attached the SSH terminal channel. The relay closes itself when the
/// bridge fires `onClose`, when an explicit `tearDown()` arrives from the
/// workspace (panel close), or when the master-fd read loop notices EOF.
@MainActor
final class RemoteTerminalPTYRelay {

    // MARK: Identity

    /// Surface id passed to `attachSurface` — kept here so callers can echo
    /// it back into session snapshots without re-opening the bridge.
    let surfaceID: UUID

    // MARK: PTY state

    /// Master-side fd owned by cmux. SSH bytes are written here; Ghostty
    /// keystrokes are read here.
    private(set) var masterFd: Int32 = -1

    /// Slave-side fd. Kept open in the parent until the surface child has
    /// inherited it through the shell redirection trick; we then close it
    /// in the parent so that EOF propagates correctly on teardown.
    private var slaveFd: Int32 = -1

    /// Path to the slave PTY device (e.g. `/dev/ttys003`). Passed to
    /// Ghostty via the surface command so the spawned `sh` redirects to
    /// the right device.
    private let slavePath: String

    /// Shell command to hand to Ghostty as the surface's `initialCommand`.
    /// Opens the slave PTY device read/write, pumps it bidirectionally
    /// against the shell's own stdin/stdout (which Ghostty has wired up to
    /// its own PTY master), and exits cleanly when either side closes.
    let surfaceCommand: String

    // MARK: Bridge state

    private var bridge: SessionBridge?
    private var readLoopTask: Task<Void, Never>?
    private var isTornDown = false

    // MARK: Init / factory

    /// Create the PTY pair and build the shell command Ghostty will run.
    ///
    /// Returns `nil` if `openpty()` fails — callers must fall back to the
    /// legacy local-shell behavior in that case.
    static func make(surfaceID: UUID) -> RemoteTerminalPTYRelay? {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = name.withUnsafeMutableBufferPointer { buf -> Int32 in
            openpty(&master, &slave, buf.baseAddress, nil, nil)
        }
        guard result == 0, master >= 0, slave >= 0 else {
            return nil
        }
        // Make the master non-inheritable so Ghostty's child process never
        // sees our master fd — only the slave device path is shared with it.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        let path = name.withUnsafeBufferPointer { buf -> String in
            String(cString: buf.baseAddress!)
        }
        return RemoteTerminalPTYRelay(
            surfaceID: surfaceID,
            masterFd: master,
            slaveFd: slave,
            slavePath: path
        )
    }

    private init(surfaceID: UUID, masterFd: Int32, slaveFd: Int32, slavePath: String) {
        self.surfaceID = surfaceID
        self.masterFd = masterFd
        self.slaveFd = slaveFd
        self.slavePath = slavePath
        self.surfaceCommand = Self.buildSurfaceCommand(slavePath: slavePath)
    }

    /// Build the shell command Ghostty's PTY child will execute.
    ///
    /// Layout:
    /// - `exec 3<> <slave>`         opens the slave device read/write on fd 3
    /// - `cat <&3 &`                background pump:  slave → stdout (Ghostty parser)
    /// - `cat >&3`                  foreground pump:  stdin (Ghostty keys) → slave
    /// - on exit, `kill $!` reaps the background reader before the shell terminates.
    private static func buildSurfaceCommand(slavePath: String) -> String {
        // Shell-escape the slave path defensively (it is normally
        // `/dev/ttysNNN`, but a future BSD layout change should not break us).
        let escaped = slavePath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        sh -c 'exec 3<>'\\''\(escaped)'\\''; cat <&3 & pid=$!; trap "kill $pid 2>/dev/null" EXIT; cat >&3'
        """
    }

    // MARK: Public API

    /// Wire the relay to a live `SessionBridge`. Begins the master-fd read
    /// loop and forwards remote PTY output into the master fd so Ghostty
    /// can display it.
    func start(bridge: SessionBridge) {
        precondition(self.bridge == nil, "RemoteTerminalPTYRelay.start called twice")
        self.bridge = bridge

        // Now that Ghostty's child has had a chance to open the slave path
        // (it does so via the shell `exec 3<>` redirection), the slave fd we
        // held in the parent is no longer needed. Closing it here is what
        // makes EOF propagate cleanly when the child exits.
        if slaveFd >= 0 {
            close(slaveFd)
            slaveFd = -1
        }

        bridge.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.writeToMaster(bytes)
        }

        bridge.onClose = { [weak self] _, _ in
            guard let self else { return }
            self.tearDown(reason: "bridge.closed")
        }

        startReadLoop()
    }

    /// Update the slave-side PTY window size and tell the daemon side too.
    /// Ghostty mirrors viewport-resize back to its own PTY via the surface
    /// API; this keeps our slave PTY in sync so any program running on the
    /// daemon side that inspects its TTY's winsize observes the truth.
    func resize(rows: UInt16, cols: UInt16, widthPx: UInt32, heightPx: UInt32) {
        guard masterFd >= 0 else { return }
        var ws = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: UInt16(min(UInt32(UInt16.max), widthPx)),
            ws_ypixel: UInt16(min(UInt32(UInt16.max), heightPx))
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
        bridge?.resize(.init(rows: rows, cols: cols, widthPx: widthPx, heightPx: heightPx))
    }

    /// Tear down the relay. Safe to call multiple times.
    func tearDown(reason: String) {
        guard !isTornDown else { return }
        isTornDown = true

        readLoopTask?.cancel()
        readLoopTask = nil

        if let bridge {
            bridge.onOutput = nil
            bridge.onClose = nil
            bridge.close()
            self.bridge = nil
        }

        if slaveFd >= 0 {
            close(slaveFd)
            slaveFd = -1
        }
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }

        #if DEBUG
        cmuxDebugLog(
            "remote.pty.tearDown surface=\(surfaceID.uuidString.prefix(5)) reason=\(reason)"
        )
        #endif
    }

    // MARK: Internals

    private func writeToMaster(_ bytes: [UInt8]) {
        guard masterFd >= 0, !bytes.isEmpty else { return }
        let fd = masterFd
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = write(fd, base.advanced(by: offset), buf.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    // EPIPE / EIO / EAGAIN — drop the rest. The read loop
                    // will notice the same fd state and tear us down.
                    break
                }
            }
        }
    }

    private func startReadLoop() {
        let fd = masterFd
        let surfaceID = self.surfaceID

        // Capture a weak ref before the detached task so the bridge can
        // outlive the relay if needed (it shouldn't, but be safe).
        readLoopTask = Task { [weak self] in
            await Self.runReadLoop(fd: fd, surfaceID: surfaceID, owner: self)
        }
    }

    private static func runReadLoop(
        fd: Int32,
        surfaceID: UUID,
        owner: RemoteTerminalPTYRelay?
    ) async {
        // Move the heavy lifting off the main actor.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var buf = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = buf.withUnsafeMutableBufferPointer { ptr -> ssize_t in
                        guard let base = ptr.baseAddress else { return 0 }
                        return read(fd, base, ptr.count)
                    }
                    if n > 0 {
                        let slice = Array(buf.prefix(Int(n)))
                        // Hop back to main actor to read `owner.bridge`
                        // safely; bridge.send is the only path off-main
                        // we need and it's async-throwing.
                        let sem = DispatchSemaphore(value: 0)
                        Task { @MainActor in
                            defer { sem.signal() }
                            guard let owner, let bridge = owner.bridge else { return }
                            do {
                                try await bridge.send(slice)
                            } catch {
                                #if DEBUG
                                cmuxDebugLog(
                                    "remote.pty.readLoop.sendErr surface=\(surfaceID.uuidString.prefix(5)) " +
                                    "err=\(error)"
                                )
                                #endif
                            }
                        }
                        sem.wait()
                    } else if n == 0 {
                        // Slave end closed. Tear down on main.
                        Task { @MainActor in
                            owner?.tearDown(reason: "master.eof")
                        }
                        break
                    } else {
                        if errno == EINTR { continue }
                        // EIO is the expected error after the slave fd
                        // closes on macOS — treat the same as EOF.
                        Task { @MainActor in
                            owner?.tearDown(reason: "master.err.\(errno)")
                        }
                        break
                    }
                }
                cont.resume()
            }
        }
    }
}
