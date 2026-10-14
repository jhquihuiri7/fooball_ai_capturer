// El tic del programa en fase con la rejilla (2026-10-14): el temporizador de antes,
// que se repetía cada 1/30 s truncado a ticks de mach, frente al que se rearma.

import Foundation
import RigCore
import XCTest

final class ProgramTickTests: XCTestCase {
    private static let frameMs = 1000.0 / 30.0
    private static let marginMs = 2.0
    private static let ns = 1_000_000.0

    func testElSiguienteTicEsElInstanteDeLaRejillaMasElMargen() {
        let fase = ProgramTickPhase(framesPerSecond: 30, marginMs: Self.marginMs)
        // El instante 30 de la rejilla está en 1000 ms; el 31, en 1033,33.
        let base: Int64 = 1_000_000_000
        XCTAssertEqual(fase.delayToNextTickNs(nowRigNs: base), 2_000_000, "en el instante: el margen")
        XCTAssertEqual(fase.delayToNextTickNs(nowRigNs: base + 500_000), 1_500_000)
        XCTAssertEqual(fase.delayToNextTickNs(nowRigNs: base + 2_000_000), 33_333_334,
                       "justo en el tic: el siguiente, un fotograma después")
        XCTAssertEqual(fase.delayToNextTickNs(nowRigNs: base + 3_000_000), 32_333_334)
        XCTAssertEqual(fase.phaseMs(nowRigNs: base + 2_000_000), 2, accuracy: 1e-6)
        XCTAssertEqual(fase.phaseMs(nowRigNs: base - 1), Self.frameMs, accuracy: 1e-5)
        XCTAssertEqual(fase.delayToNextTickNs(nowRigNs: base + 2_000_001), 33_333_333)
    }

    func testEnElRelojDelSoporteDeVerdad() {
        // Un rigMs como el del ensayo (~10,7 días de host): la coma flotante aguanta.
        let fase = ProgramTickPhase(framesPerSecond: 30, marginMs: Self.marginMs)
        let reloj = ProgramClock(frameDurationMs: Self.frameMs)
        var ahora: Int64 = 923_625_440_123_456
        for _ in 0..<1000 {
            ahora += fase.delayToNextTickNs(nowRigNs: ahora)
            XCTAssertEqual(fase.phaseMs(nowRigNs: ahora), Self.marginMs, accuracy: 1e-3)
            let ms = ahora / 1_000_000
            XCTAssertEqual(reloj.gridInstant(atOrBefore: ms),
                           reloj.instant(index: reloj.gridIndex(atOrBefore: ms)))
        }
    }

    /// 90 min con el temporizador de antes (periodo de 799 999 ticks de 125/3 ns, como en
    /// el iPhone) frente al que se rearma, los dos con 0-0,8 ms de retraso al azar en cada
    /// disparo. Con el de antes salen los huecos del ensayo; rearmado, ninguno.
    func testSinDerivaEnUnPartido() {
        let reloj = ProgramClock(frameDurationMs: Self.frameMs)
        let fase = ProgramTickPhase(framesPerSecond: 30, marginMs: Self.marginMs)
        let esperaParte: Int64 = 130, adelantoVista: Int64 = 67
        let ticks = 90 * 60 * 30
        // Un instante de la rejilla (k = 27 708 762, múltiplo de 3: exacto en ns) más la fase
        // con que arrancó el ensayo, 2,7 ms.
        let inicio: Int64 = 923_625_400_000_000 + 2_700_000

        func simula(_ siguiente: (Int64, Int) -> Int64) -> (huecosPrograma: Int, huecosDirector: Int, latenciaMax: Int64) {
            var azar: UInt64 = 7
            var programa: Int64?, director: Int64?
            var huecosP = 0, huecosD = 0
            var latMax: Int64 = 0
            var deadline = inicio
            for k in 0..<ticks {
                azar = azar &* 6364136223846793005 &+ 1442695040888963407
                let retraso = Int64(Double(azar >> 11) / Double(1 << 53) * 800_000)
                let ahora = (deadline + retraso) / 1_000_000
                let t = reloj.gridInstant(atOrBefore: ahora - esperaParte)
                let v = reloj.gridInstant(atOrBefore: ahora + adelantoVista)
                if let p = programa, reloj.gridIndex(atOrBefore: t + 1) - reloj.gridIndex(atOrBefore: p + 1) > 1 { huecosP += 1 }
                if let d = director, reloj.gridIndex(atOrBefore: v + 1) - reloj.gridIndex(atOrBefore: d + 1) > 1 { huecosD += 1 }
                programa = t
                director = v
                latMax = max(latMax, ahora - t)
                deadline = siguiente(deadline + retraso, k)
            }
            return (huecosP, huecosD, latMax)
        }

        let periodoMach = 799_999.0 * 125.0 / 3.0
        let antes = simula { _, k in inicio + Int64((Double(k + 1) * periodoMach).rounded()) }
        let ahora = simula { disparo, _ in disparo + fase.delayToNextTickNs(nowRigNs: disparo) }

        XCTAssertGreaterThan(antes.huecosDirector, 100, "el de antes se salta vistas del director")
        XCTAssertGreaterThan(antes.huecosPrograma, 100, "y, más tarde, instantes del programa")
        XCTAssertGreaterThanOrEqual(antes.latenciaMax, 162, "con un fotograma más de espera al final")
        XCTAssertEqual(ahora.huecosDirector, 0)
        XCTAssertEqual(ahora.huecosPrograma, 0)
        XCTAssertLessThanOrEqual(ahora.latenciaMax, 133 + Int64(Self.marginMs) + 2,
                                 "la espera de la parte, el redondeo de la rejilla y el margen")
    }

    func testLosInstantesQueSeSaltoElTic() {
        let r = ProgramClock(frameDurationMs: Self.frameMs)
        XCTAssertEqual(r.gridInstants(after: nil, through: 1033, limit: 4), [1033])
        XCTAssertEqual(r.gridInstants(after: 1000, through: 1033, limit: 4), [1033])
        XCTAssertEqual(r.gridInstants(after: 1000, through: 1067, limit: 4), [1033, 1067])
        XCTAssertEqual(r.gridInstants(after: 1000, through: 1067, limit: 1), [1067], "como mucho los últimos")
        XCTAssertEqual(r.gridInstants(after: 1033, through: 1033, limit: 4), [], "el mismo instante: nada")
        XCTAssertEqual(r.gridInstants(after: 1067, through: 1033, limit: 4), [], "hacia atrás: nada")
        // Instantes que redondean hacia abajo (33,33 → 33) también se reconocen.
        XCTAssertEqual(r.gridInstants(after: 33, through: 100, limit: 4), [67, 100])
    }
}
