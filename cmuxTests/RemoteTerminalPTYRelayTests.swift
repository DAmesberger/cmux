import XCTest
import Darwin
@testable import cmux_DEV

/// Tightly-focused unit tests for the M4 PTY-relay primitive. The relay
/// owns an `openpty()` pair and synthesizes the shell command Ghostty will
/// spawn to bridge that PTY into its embedded surface. The tests exercise:
///
/// 1. The PTY is actually allocated (master fd >= 0 and the device path
///    matches the OS' `/dev/ttysNN` layout).
/// 2. The surface command is well-formed shell (contains both halves of
///    the bidi pump and the slave path).
/// 3. Resize delivers the requested winsize to the master fd so the
///    kernel-side TIOCGWINSZ on the slave PTY returns matching dimensions.
///
/// We deliberately do NOT exercise `start(bridge:)`, which depends on a
/// live `Ghostty.SSHConnection` — that path is covered by the M6 smoke
/// test against a real daemon.
@MainActor
final class RemoteTerminalPTYRelayTests: XCTestCase {

    func testMakeAllocatesPTYPair() throws {
        guard let relay = RemoteTerminalPTYRelay.make(surfaceID: UUID()) else {
            XCTFail("RemoteTerminalPTYRelay.make returned nil — openpty failed")
            return
        }
        defer { relay.tearDown(reason: "test.cleanup") }

        XCTAssertGreaterThanOrEqual(relay.masterFd, 0, "master fd should be a valid descriptor")
    }

    func testSurfaceCommandReferencesSlavePath() throws {
        guard let relay = RemoteTerminalPTYRelay.make(surfaceID: UUID()) else {
            XCTFail("RemoteTerminalPTYRelay.make returned nil — openpty failed")
            return
        }
        defer { relay.tearDown(reason: "test.cleanup") }

        let command = relay.surfaceCommand
        XCTAssertTrue(
            command.contains("/dev/"),
            "surfaceCommand should reference a /dev/ pty path; got: \(command)"
        )
        XCTAssertTrue(
            command.contains("cat <&3"),
            "surfaceCommand should run a slave→stdout pump; got: \(command)"
        )
        XCTAssertTrue(
            command.contains("cat >&3"),
            "surfaceCommand should run a stdin→slave pump; got: \(command)"
        )
    }

    func testResizeUpdatesMasterWinsize() throws {
        guard let relay = RemoteTerminalPTYRelay.make(surfaceID: UUID()) else {
            XCTFail("RemoteTerminalPTYRelay.make returned nil — openpty failed")
            return
        }
        defer { relay.tearDown(reason: "test.cleanup") }

        relay.resize(rows: 42, cols: 137, widthPx: 800, heightPx: 600)

        var ws = winsize()
        let result = ioctl(relay.masterFd, TIOCGWINSZ, &ws)
        XCTAssertEqual(result, 0, "TIOCGWINSZ on master fd should succeed")
        XCTAssertEqual(ws.ws_row, 42)
        XCTAssertEqual(ws.ws_col, 137)
        XCTAssertEqual(ws.ws_xpixel, 800)
        XCTAssertEqual(ws.ws_ypixel, 600)
    }

    func testTearDownIsIdempotent() throws {
        guard let relay = RemoteTerminalPTYRelay.make(surfaceID: UUID()) else {
            XCTFail("RemoteTerminalPTYRelay.make returned nil — openpty failed")
            return
        }
        relay.tearDown(reason: "test.first")
        relay.tearDown(reason: "test.second")
        XCTAssertEqual(relay.masterFd, -1, "master fd should be closed after tearDown")
    }
}
