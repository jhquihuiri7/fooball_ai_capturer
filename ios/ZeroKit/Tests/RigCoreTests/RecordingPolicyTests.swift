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

/// 2026-10-24: la copia del programa llenó el disco del 17 y se llevó la emisión.
final class ProgramCopyPolicyTests: XCTestCase {
    private typealias P = RecordingPolicy
    private let gb: Int64 = 1_000_000_000

    func testLaCopiaSeParaAntesQueLa4KYConMargen() {
        XCTAssertGreaterThan(P.programCopyFloorBytes, P.diskFloorBytes, "la copia sobra antes que la 4K")
        XCTAssertTrue(P.programCopyAllowed(freeBytes: 3 * gb))
        XCTAssertFalse(P.programCopyAllowed(freeBytes: 3 * gb - 1))
        // El 24-oct: 0,5 GB libres a las 19:52, y la copia seguía escribiendo.
        XCTAssertFalse(P.programCopyAllowed(freeBytes: gb / 2))
        // Cinco horas más de copia (~2 GB/h) caben en lo que deja la limpieza.
        XCTAssertGreaterThanOrEqual(P.programCopyTargetFreeBytes - P.programCopyFloorBytes, 9 * gb)
    }

    func testSoloLasCopiasDelProgramaDeDocuments() {
        XCTAssertTrue(P.isProgramCopy("program-m_f50b97dd8d1a-1792885593.mov"))
        XCTAssertTrue(P.isProgramCopy("program-m_f50b97dd8d1a-1792885593-2.mov"))
        XCTAssertFalse(P.isProgramCopy("left-1792087110.mov"), "la 4K no")
        XCTAssertFalse(P.isProgramCopy("rig.json"))
        XCTAssertFalse(P.isProgramCopy("program-m_x.json"))
    }

    /// Las más viejas primero, solo hasta dejar el objetivo libre, y nunca la que se escribe.
    func testSeBorranLasMasViejasHastaDejarSitio() {
        let copias = [
            P.StoredCopy(name: "c", bytes: 6 * gb, modifiedS: 300),
            P.StoredCopy(name: "a", bytes: 2 * gb, modifiedS: 100),
            P.StoredCopy(name: "actual", bytes: 4 * gb, modifiedS: 50),
            P.StoredCopy(name: "b", bytes: 5 * gb, modifiedS: 200),
        ]
        // 4 GB libres y 12 de objetivo: hacen falta 8. La "actual" se salta aunque sea la más
        // vieja; "a" (2) y "b" (5) no bastan, "c" (6) sí.
        XCTAssertEqual(P.programCopiesToDelete(copias, freeBytes: 4 * gb, targetFreeBytes: 12 * gb,
                                               keeping: ["actual"]), ["a", "b", "c"])
        XCTAssertEqual(P.programCopiesToDelete(copias, freeBytes: 6 * gb, targetFreeBytes: 12 * gb,
                                               keeping: ["actual"]), ["a", "b"])
        // Con sitio de sobra, nada.
        XCTAssertEqual(P.programCopiesToDelete(copias, freeBytes: 30 * gb), [])
        // Sin copias que borrar, nada, aunque no llegue.
        XCTAssertEqual(P.programCopiesToDelete([], freeBytes: gb), [])
    }
}
