import RigCore
import XCTest

final class RecordingPolicyTests: XCTestCase {
    func testLa4KSoloArrancaConLaReservaLibre() {
        XCTAssertEqual(RecordingPolicy.phoneDiskReserveBytes, 40_000_000_000)
        XCTAssertTrue(RecordingPolicy.allowsLocalRecording(freeBytes: 40_000_000_000))
        XCTAssertTrue(RecordingPolicy.allowsLocalRecording(freeBytes: 120_000_000_000))
        XCTAssertFalse(RecordingPolicy.allowsLocalRecording(freeBytes: 39_999_999_999))
        XCTAssertFalse(RecordingPolicy.allowsLocalRecording(freeBytes: 0))
    }
}
