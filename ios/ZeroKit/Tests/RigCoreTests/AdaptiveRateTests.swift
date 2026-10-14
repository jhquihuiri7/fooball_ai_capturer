import XCTest

@testable import RigCore

/// El bitrate adaptativo del programa (IOS-56): los casos de AdaptiveBitRateTests del
/// directo al pod (RunnerTests), portados, y la muestra de cada segundo.
final class AdaptiveRateTests: XCTestCase {
    // MARK: - Portados de AdaptiveBitRateTests

    func testBacksOffToWhatActuallyWentOutWithMargin() {
        // Codificando a 15 Mbit/s salieron 2: se baja a 1,6 (el 80 % de lo que cupo).
        XCTAssertEqual(AdaptiveRate.next(current: 15_000_000, measured: 2_000_000), 1_600_000)
    }

    func testNeverRaisesOnACongestionSignal() {
        // Si lo medido supera lo codificado es un pico del búfer vaciándose: no se sube por eso.
        XCTAssertEqual(AdaptiveRate.next(current: 6_000_000, measured: 20_000_000), 6_000_000)
    }

    func testHalvesWhenNothingWentOutAndNeverGoesBelowTheFloor() {
        XCTAssertEqual(AdaptiveRate.next(current: 8_000_000, measured: 0), 4_000_000)
        XCTAssertEqual(AdaptiveRate.next(current: 1_500_000, measured: 0), AdaptiveRate.minimumBps)
        XCTAssertEqual(AdaptiveRate.next(current: 15_000_000, measured: 100_000), AdaptiveRate.minimumBps)
    }

    func testTheProgramStartsAtTheCeiling() {
        // El pod arrancaba bajo por RTMP; el programa sale al techo del contrato (6 Mbit/s)
        // y baja en el primer segundo si no cabe.
        XCTAssertEqual(AdaptiveRate(maximumBps: 6_000_000).currentBps, 6_000_000)
        XCTAssertEqual(AdaptiveRate(maximumBps: 6_000_000, startBps: 4_000_000).currentBps, 4_000_000)
        XCTAssertEqual(AdaptiveRate(maximumBps: 6_000_000, startBps: 9_000_000).currentBps, 6_000_000)
        XCTAssertEqual(AdaptiveRate(maximumBps: 6_000_000, startBps: 10).currentBps, AdaptiveRate.minimumBps)
    }

    // MARK: - La muestra de cada segundo

    func testCongestionBacksOffOnceAndHoldsWhileItLasts() {
        var r = AdaptiveRate(maximumBps: 6_000_000)
        XCTAssertEqual(r.sample(congested: true, measuredBps: 3_000_000), 2_400_000)
        // Sigue congestionado y sale lo mismo: 0,8 × 3 ya no baja de 2,4.
        XCTAssertNil(r.sample(congested: true, measuredBps: 3_000_000))
        XCTAssertEqual(r.currentBps, 2_400_000)
    }

    func testRaisesOneStepAfterFifteenQuietSecondsUpToTheCeiling() {
        var r = AdaptiveRate(maximumBps: 6_000_000, startBps: 5_000_000)
        for segundo in 1..<AdaptiveRate.raiseAfterSamples {
            XCTAssertNil(r.sample(congested: false, measuredBps: 5_000_000), "segundo \(segundo)")
        }
        XCTAssertEqual(r.sample(congested: false, measuredBps: 5_000_000), 5_600_000)
        for _ in 1..<AdaptiveRate.raiseAfterSamples { _ = r.sample(congested: false, measuredBps: 5_600_000) }
        // El escalón es 0,6 Mbit/s, pero no pasa del techo.
        XCTAssertEqual(r.sample(congested: false, measuredBps: 5_600_000), 6_000_000)
        for _ in 0..<(3 * AdaptiveRate.raiseAfterSamples) {
            XCTAssertNil(r.sample(congested: false, measuredBps: 6_000_000))
        }
    }

    func testACongestionRestartsTheCountToRaise() {
        var r = AdaptiveRate(maximumBps: 6_000_000, startBps: 3_000_000)
        for _ in 1..<AdaptiveRate.raiseAfterSamples { _ = r.sample(congested: false, measuredBps: 3_000_000) }
        _ = r.sample(congested: true, measuredBps: 4_000_000)  // 0,8 × 4 = 3,2: se queda en 3
        XCTAssertEqual(r.currentBps, 3_000_000)
        for _ in 1..<AdaptiveRate.raiseAfterSamples {
            XCTAssertNil(r.sample(congested: false, measuredBps: 3_000_000))
        }
        XCTAssertEqual(r.sample(congested: false, measuredBps: 3_000_000), 3_600_000)
    }

    func testTheLadderCeilingAppliesAtOnceAndRaisesStopThere() {
        // La escalera en L3 deja el techo en ×0,6: de 6 a 3,6 Mbit/s en la misma muestra.
        var r = AdaptiveRate(maximumBps: 6_000_000)
        let techo = Int(6_000_000 * LadderConstants.bitrateFactorL3)
        XCTAssertEqual(r.sample(congested: false, measuredBps: 6_000_000, ceilingBps: techo), techo)
        for _ in 0..<(2 * AdaptiveRate.raiseAfterSamples) {
            XCTAssertNil(r.sample(congested: false, measuredBps: techo, ceilingBps: techo))
        }
        // Sale de L3: la red llevaba más de 15 s tranquila, así que sube un escalón ya, y
        // el siguiente a los 15 s.
        XCTAssertEqual(r.sample(congested: false, measuredBps: techo), techo + 600_000)
        for _ in 1..<AdaptiveRate.raiseAfterSamples {
            XCTAssertNil(r.sample(congested: false, measuredBps: techo + 600_000))
        }
        XCTAssertEqual(r.sample(congested: false, measuredBps: techo + 600_000), techo + 1_200_000)
    }

    func testACutThatEndsInAReconnectionDoesNotCostTheBitrate() {
        // MediaMTX cae: el búfer de SRT pasa del umbral y no sale nada; se baja a la mitad
        // cada segundo (la regla del pod) hasta que la conexión se da por rota.
        var r = AdaptiveRate(maximumBps: 6_000_000)
        XCTAssertEqual(r.sample(congested: true, measuredBps: 0), 3_000_000)
        XCTAssertEqual(r.sample(congested: true, measuredBps: 0), 1_500_000)
        XCTAssertEqual(r.sample(congested: true, measuredBps: 0), 1_000_000)
        // Al reconectar, el de antes del corte.
        XCTAssertEqual(r.reset(), 6_000_000)
        XCTAssertNil(r.reset(), "solo una vez")
        // Con la escalera abajo, hasta su techo.
        _ = r.sample(congested: true, measuredBps: 0)
        XCTAssertEqual(r.reset(ceilingBps: 3_600_000), 3_600_000)
        // Una congestión con algo de salida es ancho de banda de verdad: no se deshace.
        _ = r.sample(congested: true, measuredBps: 0)
        _ = r.sample(congested: true, measuredBps: 2_000_000)
        XCTAssertNil(r.reset())
        XCTAssertEqual(r.currentBps, 1_600_000)
    }

    func testReconnectingKeepsTheBitrateAndRestartsTheCount() {
        var r = AdaptiveRate(maximumBps: 6_000_000)
        _ = r.sample(congested: true, measuredBps: 2_000_000)
        for _ in 1..<AdaptiveRate.raiseAfterSamples { _ = r.sample(congested: false, measuredBps: 1_600_000) }
        r.reset()
        XCTAssertEqual(r.currentBps, 1_600_000)
        XCTAssertNil(r.sample(congested: false, measuredBps: 1_600_000), "la cuenta empezó de nuevo")
    }
}
