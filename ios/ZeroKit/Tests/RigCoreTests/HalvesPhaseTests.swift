// La fase entre las cámaras por minuto (SPK-04, 2026-10-14): la deriva del ensayo de
// 90 min, con su cruce de medio fotograma.

import Foundation
import RigCore
import XCTest

final class HalvesPhaseTests: XCTestCase {
    private static let frameMs = 1000.0 / 30.0

    /// La fase del ensayo: −1 ms al arrancar y +0,8 ms/min, plegada en ±½ fotograma como
    /// la ve el maestro (su fotograma más cercano a la parte).
    private static func fase(minuto m: Double) -> Double {
        var v = -1 + 0.8 * m
        while v > frameMs / 2 { v -= frameMs }
        return v
    }

    func testLaDerivaDelEnsayoConSuCruce() {
        let inicio: Int64 = 923_625_440
        let f = HalvesPhaseTracker(startRigMs: inicio, frameDurationMs: Self.frameMs)
        // Dos lentes del minuto 0 al 22, el 36 y del 41 al 44, como en el ensayo.
        let minutos = Array(0...22) + [36] + Array(41...44)
        for m in minutos {
            for k in 0..<600 {
                let t = inicio + Int64(m) * 60_000 + Int64(k) * 100
                let s = Self.fase(minuto: Double(t - inicio) / 60_000)
                let desgarro = abs(s.rounded()) > Self.frameMs / 2
                f.record(atRigMs: t, skewMs: s.rounded(), torn: desgarro)
            }
        }
        let cubos = f.buckets
        XCTAssertEqual(cubos.map(\.index), minutos)
        XCTAssertEqual(cubos.first?.medianMs ?? 99, -1, accuracy: 1)
        XCTAssertEqual(cubos.first { $0.index == 20 }?.medianMs ?? 0, 15, accuracy: 1)
        XCTAssertLessThan(cubos.first { $0.index == 23 - 1 }?.medianMs ?? 0, 0, "pasado el cruce, al otro lado")
        XCTAssertGreaterThan(cubos.filter { $0.torn > 0 }.map(\.index).count, 0)
        XCTAssertTrue(cubos.filter { $0.torn > 0 }.allSatisfy { (20...22).contains($0.index) },
                      "los desgarros, solo alrededor del cruce")
        XCTAssertEqual(f.driftMsPerMinute() ?? 0, 0.8, accuracy: 0.05, "desenrollada a través del cruce")
        // En el minuto 44 la fase está en ~+34 − 33,3 ≈ +1: le quedan ~(16,7 − 1)/0,8 min.
        XCTAssertEqual(f.minutesToHalfFrame() ?? 0, (Self.frameMs / 2 - Self.fase(minuto: 44.5)) / 0.8, accuracy: 1.5)
    }

    func testSinDosLentesNoHayDeriva() {
        let f = HalvesPhaseTracker(startRigMs: 0, frameDurationMs: Self.frameMs)
        XCTAssertNil(f.driftMsPerMinute())
        XCTAssertNil(f.minutesToHalfFrame())
        for k in 0..<10 { f.record(atRigMs: Int64(k) * 33, skewMs: 4, torn: false) }
        XCTAssertEqual(f.buckets, [HalvesPhaseTracker.Bucket(index: 0, medianMs: 4, frames: 10, torn: 0)])
        XCTAssertNil(f.driftMsPerMinute(), "un minuto con pocos fotogramas no da recta")
    }

    func testAcotado() {
        let f = HalvesPhaseTracker(startRigMs: 0, frameDurationMs: Self.frameMs, bucketMs: 1000, maxBuckets: 5)
        for k in 0..<300 { f.record(atRigMs: Int64(k) * 100, skewMs: 0, torn: false) }
        XCTAssertEqual(f.buckets.map(\.index), [24, 25, 26, 27, 28, 29], "5 cerrados y el abierto")
    }
}
