import XCTest

@testable import RigCore

/// La cadencia común aplicada tic a tic (IOS-25 con la escalera, IOS-06): los dos móviles
/// detectan en los mismos instantes del soporte, a la cadencia que mande la escalera.
final class DetectionGateTests: XCTestCase {
    private let fotogramaMs = 1000.0 / 30

    /// Los instantes que da la puerta con fotogramas a 30 fps desplazados `faseMs` y un tic
    /// a 30 Hz que ve el último fotograma, durante `segundos`.
    private func instantes(hz: Double, faseMs: Double, segundos: Double, desde: Double = 1000) -> [Int64] {
        var puerta = DetectionGate(frameDurationMs: fotogramaMs)
        puerta.set(hz: hz)
        var dados: [Int64] = []
        var n = 0.0
        while n * fotogramaMs < segundos * 1000 {
            let fotograma = Int64((desde + n * fotogramaMs + faseMs).rounded())
            if let t = puerta.due(latestRigMs: fotograma) {
                // El fotograma más cercano a t que hay en el anillo, a ≤½ fotograma.
                XCTAssertLessThanOrEqual(abs(fotograma - t), Int64(fotogramaMs) + puerta.halfFrameMs)
                dados.append(t)
            }
            n += 1
        }
        return dados
    }

    func testA75HzUnoDeCadaCuatroFotogramasEnLaRejillaDelSoporte() {
        let t = instantes(hz: 7.5, faseMs: 0, segundos: 10)
        XCTAssertEqual(t.count, 75, accuracy: 1)
        let cadencia = DetectionCadence(hz: 7.5)
        for instante in t {
            XCTAssertEqual(instante, cadencia.instant(cadencia.index(nearest: instante)), "en la rejilla k/7,5 Hz")
        }
    }

    func testLosDosMovilesDetectanLosMismosInstantesConSuFase() {
        // Las cámaras desfasadas hasta 5 ms (ADR 0012): los mismos t_k, así que el director
        // los empareja con desfase cero.
        for hz in [LadderConstants.playerHzL0, LadderConstants.playerHzL1] {
            XCTAssertEqual(instantes(hz: hz, faseMs: 0, segundos: 20), instantes(hz: hz, faseMs: 4.5, segundos: 20))
        }
    }

    func testCambiarLaCadenciaEmpiezaLaRejillaNuevaYCeroLaApaga() {
        var puerta = DetectionGate(frameDurationMs: fotogramaMs)
        puerta.set(hz: LadderConstants.playerHzL0)
        var dados: [Int64] = []
        for n in 0..<90 {
            let f = Int64((1000 + Double(n) * fotogramaMs).rounded())
            if n == 30 { puerta.set(hz: LadderConstants.playerHzL1) }
            if n == 60 { puerta.set(hz: 0) }
            if let t = puerta.due(latestRigMs: f) { dados.append(t) }
        }
        let a5 = dados.filter { $0 >= 2000 }
        XCTAssertFalse(a5.isEmpty)
        XCTAssertTrue(a5.allSatisfy { $0 % 200 == 0 }, "a 5 Hz, la rejilla de 200 ms: \(a5)")
        XCTAssertTrue(dados.allSatisfy { $0 < 3000 }, "desde el 0, nada")
        XCTAssertEqual(puerta.hz, 0)
    }

    func testUnTicTardeVaAlInstanteMasRecienteYCuentaLosSaltados() {
        var puerta = DetectionGate(frameDurationMs: fotogramaMs)
        puerta.set(hz: 5)
        XCTAssertEqual(puerta.due(latestRigMs: 1000), 1000)
        XCTAssertNil(puerta.due(latestRigMs: 1033))
        // El tic se para 700 ms: 1200 y 1400 caducaron; toca el de 1600.
        XCTAssertEqual(puerta.due(latestRigMs: 1700), 1600)
        XCTAssertEqual(puerta.skipped, 2)
        XCTAssertNil(puerta.due(latestRigMs: 1733))
        XCTAssertEqual(puerta.due(latestRigMs: 1800), 1800)
    }
}
