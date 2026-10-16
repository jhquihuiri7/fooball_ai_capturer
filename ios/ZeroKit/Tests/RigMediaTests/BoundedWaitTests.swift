// La espera con plazo de `applicationWillTerminate` (2026-10-15): vuelve a tiempo aunque la
// cola no responda, y en el acto si responde.

import XCTest
@testable import RigMedia

final class BoundedWaitTests: XCTestCase {
    private let cola = DispatchQueue(label: "io.footballai.tests.bounded-wait")

    func testItReturnsTrueAsSoonAsTheWorkReportsDone() {
        var hecho = false
        let t0 = DispatchTime.now()
        let aTiempo = BoundedWait.run(on: cola, timeoutS: 2.0) { done in
            hecho = true
            done()
        }
        XCTAssertTrue(aTiempo)
        XCTAssertTrue(cola.sync { hecho })
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9, 1.0)
    }

    func testItGivesUpAtTheDeadlineWhenTheQueueIsStuck() {
        let atasco = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now()
        let aTiempo = BoundedWait.run(on: cola, timeoutS: 0.2) { _ in
            atasco.wait()  // la cola no vuelve hasta que la prueba la suelte
        }
        let tardo = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        XCTAssertFalse(aTiempo)
        XCTAssertGreaterThanOrEqual(tardo, 0.2)
        XCTAssertLessThan(tardo, 1.5)
        atasco.signal()
    }

    func testWorkThatFinishesLateStillCompletesWithoutTheCaller() {
        let acabo = expectation(description: "el trabajo termina solo")
        let aTiempo = BoundedWait.run(on: cola, timeoutS: 0.05) { done in
            Thread.sleep(forTimeInterval: 0.2)
            done()
            acabo.fulfill()
        }
        XCTAssertFalse(aTiempo)
        wait(for: [acabo], timeout: 2.0)
    }
}
