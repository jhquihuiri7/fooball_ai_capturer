import XCTest

@testable import RigCore

/// La tabla de secuencias de la escalera (IOS-06): niveles y tiempos esperados.
final class DegradationLadderTests: XCTestCase {
    func testWorseningIsImmediateAndRecoveryWaits() {
        var escalera = DegradationLadder()

        // Se calienta: sube de golpe.
        XCTAssertEqual(escalera.step(thermal: .serious, pressure: .nominal, charging: true, dtS: 1), .l2)

        // Se enfría: no baja hasta sostenerlo recoverS segundos…
        for _ in 0..<59 {
            XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l2)
        }
        // …y entonces baja UN escalón, no de golpe.
        XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l1)
        for _ in 0..<59 {
            XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l1)
        }
        XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l0)
    }

    func testARelapseResetsTheRecoveryClock() {
        var escalera = DegradationLadder()
        escalera.step(thermal: .serious, pressure: .nominal, charging: true, dtS: 1)

        // 50 s enfriándose… y recae: el contador vuelve a cero.
        for _ in 0..<50 {
            escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1)
        }
        XCTAssertEqual(escalera.step(thermal: .serious, pressure: .nominal, charging: true, dtS: 1), .l2)
        for _ in 0..<59 {
            XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l2)
        }
        XCTAssertEqual(escalera.step(thermal: .nominal, pressure: .nominal, charging: true, dtS: 1), .l1)
    }

    func testPressureAndThermalTakeTheWorst() {
        XCTAssertEqual(DegradationLadder.target(thermal: .nominal, pressure: .shutdown, charging: true), .l4)
        XCTAssertEqual(DegradationLadder.target(thermal: .critical, pressure: .nominal, charging: true), .l3)
        XCTAssertEqual(DegradationLadder.target(thermal: .fair, pressure: .serious, charging: true), .l2)
    }

    func testRunningOnBatteryCostsOneLevel() {
        XCTAssertEqual(DegradationLadder.target(thermal: .nominal, pressure: .nominal, charging: false), .l1)
        XCTAssertEqual(DegradationLadder.target(thermal: .critical, pressure: .nominal, charging: false), .l4)
    }

    func testTheOwnersOrderOfSacrifice() {
        let l1 = LadderActions.actions(for: .l1, role: .master)
        XCTAssertFalse(l1.ballEnabled)
        XCTAssertEqual(l1.playerHz, LadderConstants.playerHzL1)
        XCTAssertTrue(l1.aiEnabled)
        XCTAssertEqual(l1.programHeight, 1080)

        let l2 = LadderActions.actions(for: .l2, role: .master)
        XCTAssertFalse(l2.aiEnabled)
        XCTAssertEqual(l2.programBitrateFactor, 1.0)

        let l3 = LadderActions.actions(for: .l3, role: .master)
        XCTAssertEqual(l3.programHeight, 720)
        XCTAssertEqual(l3.programBitrateFactor, 0.6, accuracy: 1e-9)
        XCTAssertTrue(l3.programEnabled)

        // La grabación local es la última línea: ningún nivel la toca.
        for nivel in LadderLevel.allCases {
            XCTAssertTrue(LadderActions.actions(for: nivel, role: .slave).localRecording)
        }
    }

    func testLevelFourSplitsByRole() {
        let esclavo = LadderActions.actions(for: .l4, role: .slave)
        XCTAssertFalse(esclavo.partEnabled)
        XCTAssertFalse(esclavo.requestsHandover)

        let maestro = LadderActions.actions(for: .l4, role: .master)
        XCTAssertTrue(maestro.partEnabled)
        XCTAssertTrue(maestro.requestsHandover)
        // Sin esclavo sano sigue como en L3: el programa no se apaga.
        XCTAssertTrue(maestro.programEnabled)
        XCTAssertEqual(maestro.programHeight, 720)
    }
}
