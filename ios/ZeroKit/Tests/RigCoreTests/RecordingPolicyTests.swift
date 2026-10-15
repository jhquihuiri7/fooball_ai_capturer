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

/// 2026-10-14, la cancha: el banco largo del plan B, los fragmentos y el suelo del disco.
final class RecordingPolicyFieldTests: XCTestCase {
    func testUnBancoLargoNoPideMasQueUnPartido() {
        // 6000 s a 45 Mbit/s son 33,75 GB: con el ×2 pedía 69,5 GB y la 4K no arrancaba.
        XCTAssertEqual(RecordingPolicy.benchReserveBytes(durationS: 6000), RecordingPolicy.phoneDiskReserveBytes)
        // 20 min siguen con su ×2 (13,5 + 2 GB), por debajo de los 40.
        XCTAssertEqual(RecordingPolicy.benchReserveBytes(durationS: 1200), 15_500_000_000)
        // Una pasada que no cabe en los 40 GB pide al menos lo suyo y el colchón.
        XCTAssertEqual(RecordingPolicy.benchReserveBytes(durationS: 9000), 52_625_000_000)
    }

    func testLosFragmentosCadaDiezSegundos() {
        XCTAssertEqual(RecordingPolicy.movieFragmentIntervalS, 10)
    }

    func testLa4KSeCierraConMenosDeDosGigasLibres() {
        XCTAssertEqual(RecordingPolicy.diskFloorBytes, 2_000_000_000)
        XCTAssertTrue(RecordingPolicy.mustStopForDisk(freeBytes: 1_999_999_999))
        XCTAssertTrue(RecordingPolicy.mustStopForDisk(freeBytes: 0))
        XCTAssertFalse(RecordingPolicy.mustStopForDisk(freeBytes: 2_000_000_000))
    }
}
