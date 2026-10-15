// El spike de la duración de fotograma (2026-10-15): el entorno, el plan sobre el reloj
// del soporte, lo que da la cámara cada 10 s y cuánto tarda en notarse un cambio.

import Foundation
import RigCore
import XCTest

final class FrameDurationSpikeTests: XCTestCase {
    private static let nominal = FrameDuration.nominal(fps: 30)
    private static let alargada = FrameDuration(value: 33_367, timescale: 1_000_000)!
    private static let nominalNs = 1_000_000_000.0 / 30

    // MARK: - FrameDuration

    func testLeeMicrosegundosYValorEscala() throws {
        let us = try XCTUnwrap(FrameDuration.parse("33367"))
        XCTAssertEqual(us, Self.alargada)
        XCTAssertEqual(us.microseconds, 33_367, accuracy: 1e-9)
        XCTAssertEqual(us.description, "33367/1000000")
        let ntsc = try XCTUnwrap(FrameDuration.parse(" 1001/30000 "))
        XCTAssertEqual(ntsc.value, 1001)
        XCTAssertEqual(ntsc.timescale, 30_000)
        XCTAssertEqual(ntsc.microseconds, 33_366.667, accuracy: 1e-3)
        XCTAssertEqual(Self.nominal.microseconds, 33_333.333, accuracy: 1e-3)
        for malo in ["", "abc", "0", "-5", "1/0", "0/30", "1/2/3", "33367.5", "/30"] {
            XCTAssertNil(FrameDuration.parse(malo), malo)
        }
    }

    // MARK: - El plan del entorno

    func testSinDuracionNoHayPlan() throws {
        XCTAssertNil(try FrameDurationSpikePlan.parse(environment: [:]))
        XCTAssertNil(try FrameDurationSpikePlan.parse(environment: ["RIG_SPIKE_FRAME_SIDE": "right"]))
    }

    func testElPlanConSusValoresPorDefecto() throws {
        let p = try XCTUnwrap(FrameDurationSpikePlan.parse(environment: [
            "RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right",
        ]))
        XCTAssertEqual(p.durations, [Self.alargada])
        XCTAssertEqual(p.sides, .right)
        XCTAssertEqual(p.onMs, 20_000)
        XCTAssertEqual(p.everyMs, 120_000)
        XCTAssertEqual(p.afterS, 60)
        let varias = try XCTUnwrap(FrameDurationSpikePlan.parse(environment: [
            "RIG_SPIKE_FRAME_US": "33367,1001/30000", "RIG_SPIKE_FRAME_SIDE": "alternate",
            "RIG_SPIKE_FRAME_ON_S": "10", "RIG_SPIKE_FRAME_EVERY_S": "60", "RIG_SPIKE_FRAME_AFTER_S": "0",
        ]))
        XCTAssertEqual(varias.durations.map(\.description), ["33367/1000000", "1001/30000"])
        XCTAssertEqual(varias.sides, .alternate)
        XCTAssertEqual(varias.onMs, 10_000)
        XCTAssertEqual(varias.everyMs, 60_000)
        XCTAssertEqual(varias.afterS, 0)
    }

    func testLoQueNoSeEntiendeEsUnError() {
        let malos: [[String: String]] = [
            ["RIG_SPIKE_FRAME_US": "33367"],  // sin lado: llega igual a los dos
            ["RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "arriba"],
            ["RIG_SPIKE_FRAME_US": "33367,abc", "RIG_SPIKE_FRAME_SIDE": "right"],
            ["RIG_SPIKE_FRAME_US": "", "RIG_SPIKE_FRAME_SIDE": "right"],
            ["RIG_SPIKE_FRAME_US": "333670", "RIG_SPIKE_FRAME_SIDE": "right"],  // un cero de más
            ["RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right", "RIG_SPIKE_FRAME_ON_S": "x"],
            ["RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right", "RIG_SPIKE_FRAME_ON_S": "120"],
            ["RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right", "RIG_SPIKE_FRAME_ON_S": "0"],
            ["RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right", "RIG_SPIKE_FRAME_AFTER_S": "-1"],
        ]
        for env in malos {
            XCTAssertThrowsError(try FrameDurationSpikePlan.parse(environment: env), "\(env)")
        }
    }

    // MARK: - Las ventanas, en el reloj del soporte

    /// 20 s cada 120 s al derecho: de 0 a 20 s de cada múltiplo de 120 s del reloj del
    /// soporte, y solo las que empiezan con la pasada ya 60 s en marcha.
    func testLasVentanasVanEnLaRejillaDelSoporte() {
        let p = FrameDurationSpikePlan(durations: [Self.alargada], sides: .right, onMs: 20_000, everyMs: 120_000,
                                       afterS: 60)
        let arranque: Int64 = 1_070_000  // el reloj del soporte cuando empezó la pasada
        func bench(_ rig: Int64) -> Double { Double(rig - arranque) / 1000 }
        // La ventana 9 (1 080 000) empieza a los 10 s de pasada: antes de los 60, no cuenta.
        XCTAssertNil(p.window(atRigMs: 1_085_000, benchS: bench(1_085_000)))
        // La 10 (1 200 000), a los 130 s.
        let w = p.window(atRigMs: 1_200_000, benchS: bench(1_200_000))
        XCTAssertEqual(w, .init(index: 10, startRigMs: 1_200_000, endRigMs: 1_220_000, side: .right,
                                duration: Self.alargada))
        XCTAssertEqual(p.duration(for: .right, atRigMs: 1_219_999, benchS: bench(1_219_999)), Self.alargada)
        XCTAssertNil(p.duration(for: .left, atRigMs: 1_210_000, benchS: bench(1_210_000)), "solo el derecho")
        XCTAssertNil(p.duration(for: .right, atRigMs: 1_220_000, benchS: bench(1_220_000)), "acabó")
        XCTAssertNil(p.duration(for: .right, atRigMs: 1_319_999, benchS: bench(1_319_999)))
        XCTAssertEqual(p.duration(for: .right, atRigMs: 1_320_000, benchS: bench(1_320_000)), Self.alargada)
        // Las que empiezan en una pasada de 10 min, para el informe.
        XCTAssertEqual(p.windows(fromRigMs: arranque, toRigMs: arranque + 600_000).map(\.startRigMs),
                       [1_080_000, 1_200_000, 1_320_000, 1_440_000, 1_560_000])
        XCTAssertEqual(p.windows(fromRigMs: 1_200_000, toRigMs: 1_200_001).map(\.index), [10])
        XCTAssertEqual(p.windows(fromRigMs: 5, toRigMs: 5), [])
    }

    func testPorTurnosYConVariasDuraciones() throws {
        let ntsc = try XCTUnwrap(FrameDuration.parse("1001/30000"))
        let p = FrameDurationSpikePlan(durations: [Self.alargada, ntsc], sides: .alternate, onMs: 10_000,
                                       everyMs: 60_000, afterS: 0)
        let ventanas = p.windows(fromRigMs: 0, toRigMs: 240_000)
        XCTAssertEqual(ventanas.map(\.side), [.right, .left, .right, .left])
        XCTAssertEqual(ventanas.map(\.duration), [Self.alargada, ntsc, Self.alargada, ntsc])
        XCTAssertEqual(p.duration(for: .left, atRigMs: 65_000, benchS: 65), ntsc)
        XCTAssertNil(p.duration(for: .right, atRigMs: 65_000, benchS: 65))
        // Un reloj del soporte negativo no rompe la rejilla.
        XCTAssertEqual(p.window(atRigMs: -55_000, benchS: 100)?.index, -1)
    }

    /// La predicción del spike: 33 367 µs frente a 1/30 son ~0,034 ms por fotograma, ~1 ms
    /// por segundo; 20 s mueven la fase ~20 ms.
    func testLaPrediccionDelRetraso() {
        let p = FrameDurationSpikePlan(durations: [Self.alargada], sides: .right, onMs: 20_000, everyMs: 120_000,
                                       afterS: 60)
        XCTAssertEqual(p.predictedShiftMs(Self.alargada, nominal: Self.nominal), 20.18, accuracy: 0.01)
        let porFotograma = Self.alargada.microseconds - Self.nominal.microseconds
        XCTAssertEqual(porFotograma, 33.67, accuracy: 0.01, "µs por fotograma")
        XCTAssertEqual(p.predictedShiftMs(Self.nominal, nominal: Self.nominal), 0)
    }

    /// La fase del maestro se lee plegada en ±½ fotograma y una ventana la mueve más de ½
    /// fotograma: se desenrolla cubo a cubo.
    func testLoQueSeMovioLaFaseCuboACubo() throws {
        let t = 1000.0 / 30
        let w = FrameDurationSpikePlan.Window(index: 10, startRigMs: 1_200_000, endRigMs: 1_220_000, side: .right,
                                              duration: Self.alargada)
        func movida(_ medianas: [Double], desde: Int64 = 1_190_000) -> Double? {
            let fases = medianas.enumerated().map { (startRigMs: desde + Int64($0.offset) * 10_000, medianMs: $0.element) }
            return FrameDurationSpikePlan.measuredShiftMs(phases: fases, window: w, bucketMs: 10_000, frameDurationMs: t)
        }
        // Antes, dos cubos dentro y después; uno más tarde que no cuenta.
        XCTAssertEqual(try XCTUnwrap(movida([5, 0, -10, -15, 9])), -20, accuracy: 1e-9)
        // Cruzando −½ fotograma: −20 y no +13,3.
        XCTAssertEqual(try XCTUnwrap(movida([-5, -10, -20 + t, -25 + t])), -20, accuracy: 1e-9)
        // Si la cámara no hizo caso, ~0.
        XCTAssertEqual(try XCTUnwrap(movida([4, 4.1, 4.3, 4.5])), 0.5, accuracy: 1e-9)
        // Sin el cubo de antes o el de después, no se sabe.
        XCTAssertNil(movida([0, -10, -15], desde: 1_200_000))
        XCTAssertNil(movida([5, 0, -10]))
    }

    // MARK: - Lo que da la cámara cada 10 s

    func testLaCadenciaPorCubosDeDiezSegundos() {
        let c = FrameCadenceTracker(nominalUs: Self.nominal.microseconds)
        // En el maestro el reloj del soporte es el del host: un mismo eje, en ns. El primer
        // fotograma no cae en la rejilla: su cubo empieza antes, en 1 230 000 ms.
        var t = 1_234_600.0 * 1e6
        var grabados: Int64 = 0
        func fotograma() {
            c.record(frameHostNs: Int64(t.rounded()), rigMs: Int64(t / 1e6), recordedTotal: grabados)
            grabados += 1  // entra a la 4K después
        }
        func hasta(_ finMs: Double, periodoNs: Double, perder: Double? = nil) {
            var perdido = false
            while t + periodoNs < finMs * 1e6 {
                t += periodoNs
                if let p = perder, !perdido, t > p * 1e6 {
                    perdido = true
                    c.recordDrop()  // la cámara no lo entregó
                    continue
                }
                fotograma()
            }
        }
        fotograma()
        hasta(1_240_000, periodoNs: Self.nominalNs, perder: 1_236_000)
        c.setRequested(us: Self.alargada.microseconds)
        hasta(1_250_000, periodoNs: 33_367_000)
        c.setRequested(us: nil)
        hasta(1_260_000, periodoNs: Self.nominalNs)

        let cubos = c.buckets
        XCTAssertEqual(cubos.map(\.startRigMs), [1_230_000, 1_240_000, 1_250_000])
        XCTAssertEqual(cubos[0].meanUs, 33_333.33, accuracy: 0.05, "el perdido no mueve la media")
        XCTAssertEqual(cubos[0].gaps, 1)
        XCTAssertEqual(cubos[0].drops, 1)
        XCTAssertEqual(cubos[0].requestedUs, 0)
        XCTAssertEqual(cubos[1].meanUs, 33_367, accuracy: 0.05)
        XCTAssertEqual(cubos[1].p50Us, 33_367, accuracy: 0.5)
        XCTAssertEqual(cubos[1].p99Us, 33_367, accuracy: 0.5)
        XCTAssertEqual(cubos[1].gaps, 0)
        XCTAssertEqual(cubos[1].drops, 0)
        XCTAssertEqual(cubos[1].requestedUs, Self.alargada.microseconds)
        XCTAssertTrue((299...300).contains(cubos[1].intervals), "\(cubos[1].intervals)")
        XCTAssertEqual(cubos[1].recorded, Int64(cubos[1].intervals), "lo que entró a la 4K en el cubo")
        XCTAssertEqual(cubos[2].meanUs, 33_333.33, accuracy: 0.05)
        XCTAssertEqual(cubos[2].requestedUs, 0)
    }

    func testSinRelojDelSoporteSoloGuardaElSello() {
        let c = FrameCadenceTracker(nominalUs: Self.nominal.microseconds)
        XCTAssertNil(c.record(frameHostNs: 1_000_000_000, rigMs: nil, recordedTotal: 0))
        XCTAssertNil(c.record(frameHostNs: 1_033_333_333, rigMs: nil, recordedTotal: 0))
        XCTAssertEqual(c.buckets, [])
        let periodo = c.record(frameHostNs: 1_066_666_667, rigMs: 20_000, recordedTotal: 0)
        XCTAssertEqual(periodo ?? 0, 33_333.334, accuracy: 1e-6, "el periodo del fotograma, en µs")
        XCTAssertEqual(c.buckets.count, 1)
        XCTAssertEqual(c.buckets[0].intervals, 1)
        XCTAssertEqual(c.buckets[0].gaps, 0, "el intervalo con el último sello sin reloj, no un hueco")
    }

    func testAcotado() {
        let c = FrameCadenceTracker(nominalUs: Self.nominal.microseconds, bucketMs: 1000, maxBuckets: 3)
        for k in 0..<300 {
            c.record(frameHostNs: Int64(Double(k) * Self.nominalNs), rigMs: Int64(Double(k) * Self.nominalNs / 1e6),
                     recordedTotal: 0)
        }
        XCTAssertEqual(c.buckets.map(\.startRigMs), [6000, 7000, 8000, 9000], "3 cerrados y el abierto")
    }

    // MARK: - Cuánto tarda en notarse

    func testElPrimeroDeTresSeguidosConLoPedido() {
        var e = FrameDurationEffect(fromUs: Self.nominal.microseconds, toUs: Self.alargada.microseconds,
                                    requestedAtHostNs: 1_000_000_000)
        var sello: Int64 = 1_000_000_000
        func periodo(_ us: Double) {
            sello += Int64(us * 1000)
            e.observe(periodUs: us, frameHostNs: sello)
        }
        // Cuatro a la nominal, uno suelto que lo parece (jitter), dos más y desde ahí, lo pedido.
        for _ in 0..<4 { periodo(33_333) }
        periodo(33_360)
        for _ in 0..<2 { periodo(33_333) }
        XCTAssertNil(e.framesToEffect)
        let antes = sello
        for _ in 0..<5 { periodo(33_367) }
        XCTAssertEqual(e.framesToEffect, 8, "el octavo fotograma tras la petición")
        XCTAssertEqual(e.msToEffect ?? 0, Double(antes + 33_367_000 - 1_000_000_000) / 1e6, accuracy: 1e-6)
        XCTAssertFalse(e.isComplete)
        for _ in 0..<200 { periodo(33_367) }
        XCTAssertTrue(e.isComplete)
        XCTAssertEqual(e.periodsUs.count, FrameDurationEffect.capacity)
        XCTAssertEqual(e.framesToEffect, 8, "no se mueve")
    }

    func testAlVolverALaNominal() {
        var e = FrameDurationEffect(fromUs: Self.alargada.microseconds, toUs: Self.nominal.microseconds,
                                    requestedAtHostNs: 0)
        for k in 1...3 { e.observe(periodUs: 33_367, frameHostNs: Int64(k) * 33_367_000) }
        XCTAssertNil(e.framesToEffect)
        for k in 4...6 { e.observe(periodUs: 33_333, frameHostNs: Int64(k) * 33_350_000) }
        XCTAssertEqual(e.framesToEffect, 4)
        XCTAssertEqual(e.msToEffect ?? 0, 4 * 33.35, accuracy: 1e-9)
        // Pedir lo mismo que había no se «nota» nunca.
        var igual = FrameDurationEffect(fromUs: 33_333, toUs: 33_333, requestedAtHostNs: 0)
        for k in 1...10 { igual.observe(periodUs: 33_333, frameHostNs: Int64(k)) }
        XCTAssertNil(igual.framesToEffect)
        XCTAssertEqual(igual.periodsUs.count, 10)
    }

    // MARK: - La fase del maestro en la misma rejilla

    func testLaFaseFinaCaeEnLaRejillaDelSoporte() {
        XCTAssertEqual(HalvesPhaseTracker.gridStart(1_234_567, bucketMs: 10_000), 1_230_000)
        XCTAssertEqual(HalvesPhaseTracker.gridStart(1_230_000, bucketMs: 10_000), 1_230_000)
        XCTAssertEqual(HalvesPhaseTracker.gridStart(-5, bucketMs: 10), -10)
        let inicio = HalvesPhaseTracker.gridStart(1_234_567, bucketMs: HalvesPhaseTracker.fineBucketMs)
        let f = HalvesPhaseTracker(startRigMs: inicio, frameDurationMs: 1000.0 / 30,
                                   bucketMs: HalvesPhaseTracker.fineBucketMs)
        f.record(atRigMs: 1_234_600, skewMs: 3, torn: false)
        f.record(atRigMs: 1_251_000, skewMs: -17, torn: true)
        XCTAssertEqual(f.buckets.map { f.startRigMs(of: $0) }, [1_230_000, 1_250_000])
        XCTAssertEqual(f.buckets.map(\.medianMs), [3, -17])
    }
}
