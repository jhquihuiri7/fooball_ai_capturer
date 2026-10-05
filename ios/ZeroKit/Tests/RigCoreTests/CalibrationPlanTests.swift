import XCTest

@testable import RigCore

/// La elección de destinos y de fotogramas para calibrar (IOS-70).
final class CalibrationPlanTests: XCTestCase {
    func testCincoDestinosEspaciadosUnSegundoTrasElAdelanto() {
        let t = CalibrationPlan.targets(nowRigMs: 10_000)
        XCTAssertEqual(t, [10_500, 11_500, 12_500, 13_500, 14_500])
        XCTAssertEqual(RigConstants.rigCalibPairCount, 5)
    }

    func testElMasCercanoDentroDeLaToleranciaYSiNoElSiguiente() {
        let fotos: [Int64] = [1000, 1033, 1067, 1100]
        XCTAssertEqual(CalibrationPlan.choose(available: fotos, target: 1040), 1033)
        XCTAssertEqual(CalibrationPlan.choose(available: fotos, target: 1050), 1067, "a 17 y 17 ms: el que cumple")
        // Con un hueco de fotogramas: nada a ≤16 ms, se toma el siguiente.
        XCTAssertEqual(CalibrationPlan.choose(available: [1000, 1100], target: 1040), 1100)
        XCTAssertNil(CalibrationPlan.choose(available: [1000, 1010], target: 1200), "todavía no hay fotograma")
        XCTAssertEqual(CalibrationPlan.toleranceMs, 16)
    }
}
