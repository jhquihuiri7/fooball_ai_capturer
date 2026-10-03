import XCTest

@testable import RigCore

/// El código de tiempo tiene que ser bit a bit el del servidor
/// (`tests/unit/test_timecode.py` en `football-ai`). Estos tests fijan lo que no puede
/// cambiar por un lado solo.
final class RigTimecodeWordTests: XCTestCase {
    func testCrcKnownAnswer() {
        // CRC-8/SMBUS de "123456789": la misma comprobación que hace el servidor.
        XCTAssertEqual(RigTimecode.crc8(Array("123456789".utf8)), 0xF4)
    }

    func testWordLayout() {
        let word = RigTimecode.word(valueMs: 1)
        XCTAssertEqual(word >> 56, 0xB2)
        XCTAssertEqual((word >> 8) & RigTimecode.payloadMax, 1)
        XCTAssertEqual(word & 0xFF, UInt64(RigTimecode.crc8([0, 0, 0, 0, 0, 1])))
    }

    func testCellSideMatchesServer() {
        XCTAssertEqual(RigTimecode.cellSide(width: 3840), 16)
        XCTAssertEqual(RigTimecode.cellSide(width: 1920), 8)
        XCTAssertEqual(RigTimecode.cellSide(width: 640), 4)
        XCTAssertEqual(RigTimecode.cellSide(width: 3000), 12)
    }
}
