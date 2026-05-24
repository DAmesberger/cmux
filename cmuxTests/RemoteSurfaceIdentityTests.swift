import XCTest
@testable import cmux_DEV

/// Unit tests for the M3 service_ack decode path. The 36-byte ack arrives
/// from the libghostty SSH terminal channel on `Event.opened`; cmux uses it
/// to persist the daemon-side surface UUID so a later restart can reattach
/// the same remote PTY.
///
/// Wire format (matches `cmux_terminal_service_ack` packed by the C bridge):
///
/// ```
/// offset  size  field
/// ------  ----  -----
///   0     16    group_id   (RFC 4122 / big-endian byte order)
///  16     16    surface_id (RFC 4122 / big-endian byte order)
///  32      4    history_rows (little-endian u32)
/// ```
final class RemoteSurfaceIdentityTests: XCTestCase {

    func testDecodesWellFormedAck() throws {
        let group = UUID(uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00")!
        let surface = UUID(uuidString: "DEADBEEF-CAFE-BABE-FACE-0123456789AB")!
        let historyRows: UInt32 = 0x1234_5678

        var data = Data()
        withUnsafeBytes(of: group.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: surface.uuid) { data.append(contentsOf: $0) }
        // little-endian u32
        data.append(UInt8(historyRows & 0xFF))
        data.append(UInt8((historyRows >> 8) & 0xFF))
        data.append(UInt8((historyRows >> 16) & 0xFF))
        data.append(UInt8((historyRows >> 24) & 0xFF))

        XCTAssertEqual(data.count, 36)

        guard let identity = RemoteSurfaceIdentity.decode(data) else {
            XCTFail("decode returned nil on a well-formed 36-byte ack")
            return
        }
        XCTAssertEqual(identity.groupID, group)
        XCTAssertEqual(identity.surfaceID, surface)
        XCTAssertEqual(identity.historyRows, historyRows)
    }

    func testRejectsTooShortAck() {
        let data = Data(repeating: 0, count: 35)
        XCTAssertNil(RemoteSurfaceIdentity.decode(data))
    }

    func testRejectsTooLongAck() {
        let data = Data(repeating: 0, count: 37)
        XCTAssertNil(RemoteSurfaceIdentity.decode(data))
    }

    func testRejectsEmptyAck() {
        XCTAssertNil(RemoteSurfaceIdentity.decode(Data()))
    }

    func testHistoryRowsLittleEndianOrdering() throws {
        // Confirm the decoder honors little-endian ordering for history_rows
        // even when the bytes form a value that looks meaningful big-endian.
        var data = Data(repeating: 0, count: 32) // group + surface = zero UUIDs
        data.append(0x01)
        data.append(0x00)
        data.append(0x00)
        data.append(0x00)
        guard let identity = RemoteSurfaceIdentity.decode(data) else {
            XCTFail("decode returned nil")
            return
        }
        XCTAssertEqual(identity.historyRows, 1, "least-significant byte should be at offset 32")
    }
}
