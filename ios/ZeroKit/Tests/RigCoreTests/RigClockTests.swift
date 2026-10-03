import Foundation
import XCTest

import RigCore

/// Paridad del puerto del reloj (IOS-13) contra los casos compartidos que genera la
/// referencia Dart (tools/gen_rig_clock_cases.dart): ±1 ns de desfase y ±1e-6 ppm de
/// deriva. Si esto falla, divergieron las dos implementaciones, no «falló un test».
final class RigClockTests: XCTestCase {
    private func loadCases() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/rig_clock_cases", withExtension: "json"),
            "falta Fixtures/rig_clock_cases.json: generarlo con flutter test tools/gen_rig_clock_cases.dart"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? .min
    }

    func testSolveClockSampleMatchesTheDartReference() throws {
        let doc = try loadCases()
        let cases = try XCTUnwrap(doc["solve_cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for caso in cases {
            let nombre = caso["name"] as? String ?? "?"
            let sample = solveClockSample(
                t1: int64(caso["t1"]), t2: int64(caso["t2"]),
                t3: int64(caso["t3"]), t4: int64(caso["t4"])
            )
            XCTAssertEqual(sample.roundTripNs, int64(caso["round_trip_ns"]), nombre)
            XCTAssertEqual(sample.offsetNs, int64(caso["offset_ns"]), nombre)
            XCTAssertEqual(sample.localMonotonicNs, int64(caso["local_monotonic_ns"]), nombre)
        }
    }

    func testTheClockMatchesTheDartReferenceCaseByCase() throws {
        let doc = try loadCases()
        let cases = try XCTUnwrap(doc["clock_cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for caso in cases {
            let nombre = caso["name"] as? String ?? "?"
            let clock = RigClock()
            for muestra in try XCTUnwrap(caso["samples"] as? [[String: Any]]) {
                clock.add(RigClockSample(
                    roundTripNs: int64(muestra["round_trip_ns"]),
                    offsetNs: int64(muestra["offset_ns"]),
                    localMonotonicNs: int64(muestra["local_monotonic_ns"])
                ))
            }

            if let esperado = caso["estimate"] as? [String: Any] {
                let estimate = try XCTUnwrap(clock.estimate, nombre)
                XCTAssertLessThanOrEqual(
                    abs(estimate.offsetNs - int64(esperado["offset_ns"])), 1, nombre
                )
                let driftEsperado = (esperado["drift_ppm"] as? NSNumber)?.doubleValue ?? .nan
                XCTAssertEqual(estimate.driftPpm, driftEsperado, accuracy: 1e-6, nombre)
                XCTAssertEqual(estimate.samples, (esperado["samples"] as? NSNumber)?.intValue, nombre)
                XCTAssertEqual(estimate.bestRoundTripNs, int64(esperado["best_round_trip_ns"]), nombre)
                XCTAssertEqual(estimate.uncertaintyNs, int64(esperado["uncertainty_ns"]), nombre)
            } else {
                XCTAssertNil(clock.estimate, nombre)
            }

            for consulta in try XCTUnwrap(caso["offset_at"] as? [[String: Any]]) {
                let at = int64(consulta["at_ns"])
                XCTAssertLessThanOrEqual(
                    abs(clock.offsetAt(ns: at) - int64(consulta["offset_ns"])), 1,
                    "\(nombre) en \(at)"
                )
            }
        }
    }

    /// Lo que los casos congelados no ejercitan: el dominio del soporte es local + desfase.
    func testToRigTimeAddsTheExtrapolatedOffset() {
        let clock = RigClock()
        let segundo: Int64 = 1_000_000_000
        for i in 0..<5 {
            clock.add(RigClockSample(
                roundTripNs: 2_000_000,
                offsetNs: 1_000_000,
                localMonotonicNs: Int64(10 + i) * segundo
            ))
        }
        XCTAssertEqual(clock.toRigTimeNs(20 * segundo), 20 * segundo + 1_000_000)
    }
}
