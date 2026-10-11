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

final class RecordingPolicyBenchTests: XCTestCase {
    func testLaReservaDeUnBancoEsLaDeSuDuracion() {
        // 10 min a 45 Mbit/s son 3,375 GB: por 2 y 2 GB de colchón.
        XCTAssertEqual(RecordingPolicy.benchReserveBytes(durationS: 600), 8_750_000_000)
        XCTAssertEqual(RecordingPolicy.benchReserveBytes(durationS: 0), 2_000_000_000)
        let reserva = RecordingPolicy.benchReserveBytes(durationS: 600)
        XCTAssertTrue(RecordingPolicy.allowsLocalRecording(freeBytes: 9_000_000_000, reserveBytes: reserva))
        XCTAssertFalse(RecordingPolicy.allowsLocalRecording(freeBytes: 8_000_000_000, reserveBytes: reserva))
        XCTAssertFalse(RecordingPolicy.allowsLocalRecording(freeBytes: 9_000_000_000), "el partido sigue pidiendo 40 GB")
    }
}
