// El compás propio del programa (IOS-84): líneas temporales de las fuentes.

import Foundation
import RigCore
import XCTest

final class ProgramClockTests: XCTestCase {
    /// 10 s a 30 fps: el maestro se cae a los 2 s, el esclavo a los 4 s, el maestro vuelve
    /// a los 7 s y el esclavo a los 8 s. Cada fuente, cuándo toca.
    func testMaestroFueraEsclavoFueraLosDosYVuelta() {
        let reloj = ProgramClock()
        var stats = ProgramSourceStats()
        var linea: [(Int64, ProgramSource)] = []
        for n in 0..<300 {
            let t = reloj.gridInstant(atOrBefore: Int64((Double(n) * 1000 / 30).rounded(.up)))
            let maestro = !(t >= 2000 && t < 7000)
            let esclavo = !(t >= 4000 && t < 8000)
            let s = ProgramClock.choose(masterFrame: maestro, slavePart: esclavo, instantMs: t,
                                        lastRealFrameMs: stats.lastRealFrameMs)
            stats.record(s, instantMs: t)
            if linea.last?.1 != s { linea.append((t, s)) }
        }
        let cambios = linea.map(\.1)
        XCTAssertEqual(cambios, [.twoLens, .slaveOnly, .hold, .noSignal, .masterOnly, .twoLens])
        let hold = linea.first { $0.1 == .hold }!.0, sinSenal = linea.first { $0.1 == .noSignal }!.0
        XCTAssertEqual(Double(sinSenal - hold), Double(ProgramClockConstants.holdMs), accuracy: 34)
        XCTAssertLessThanOrEqual(sinSenal - 4000, 1000, "SIN SEÑAL en ≤1 s sin ninguna cámara")
        XCTAssertEqual(stats.counts.values.reduce(0, +), 300, "el programa no se para: 30 fps siempre")
    }

    func testLaRejilla() {
        let r = ProgramClock()
        XCTAssertEqual(r.gridInstant(atOrBefore: 1000), 1000)
        XCTAssertEqual(r.gridInstant(atOrBefore: 1032), 1000)
        XCTAssertEqual(r.gridInstant(atOrBefore: 1034), 1033)
    }
}
