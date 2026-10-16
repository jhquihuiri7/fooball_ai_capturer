// La puerta de la vista previa (2026-10-15): la sesión se le pone una vez, con la app
// delante y la cámara sin interrumpir; lo demás espera y dice por qué.

import XCTest
@testable import RigMedia

final class PreviewAttachGateTests: XCTestCase {
    func testWithTheAppInFrontItAttachesOnceAndNeverAgain() {
        var puerta = PreviewAttachGate()
        XCTAssertEqual(puerta.request(), .attach)
        XCTAssertTrue(puerta.attached)
        // Otra vista de plataforma sobre la misma capa (un vistazo, PARAR): nada que tocar.
        XCTAssertEqual(puerta.request(), .nothing)
        XCTAssertEqual(puerta.app(inBackground: true), .nothing)
        XCTAssertEqual(puerta.app(inBackground: false), .nothing)
        XCTAssertEqual(puerta.session(interrupted: true), .nothing)
        XCTAssertEqual(puerta.session(interrupted: false), .nothing)
    }

    func testInTheBackgroundItWaitsAndAttachesWhenTheAppComesBack() {
        var puerta = PreviewAttachGate(appInBackground: true)
        XCTAssertEqual(puerta.request(), .wait(PreviewAttachGate.backgroundReason))
        XCTAssertFalse(puerta.attached)
        XCTAssertEqual(puerta.app(inBackground: false), .attach)
        XCTAssertTrue(puerta.attached)
    }

    func testWithTheCameraInterruptedItWaitsForTheInterruptionToEnd() {
        var puerta = PreviewAttachGate()
        XCTAssertEqual(puerta.session(interrupted: true), .nothing)  // nadie la pidió aún
        XCTAssertEqual(puerta.request(), .wait(PreviewAttachGate.interruptedReason))
        XCTAssertEqual(puerta.session(interrupted: true), .wait(PreviewAttachGate.interruptedReason))
        XCTAssertEqual(puerta.session(interrupted: false), .attach)
    }

    func testTheBackgroundInterruptionEndsAfterTheAppIsBackAndOnlyThenItAttaches() {
        // El orden real al volver del fondo: willEnterForeground primero, la cámara después.
        var puerta = PreviewAttachGate()
        XCTAssertEqual(puerta.app(inBackground: true), .nothing)
        XCTAssertEqual(puerta.session(interrupted: true), .nothing)
        XCTAssertEqual(puerta.request(), .wait(PreviewAttachGate.backgroundReason))
        XCTAssertEqual(puerta.app(inBackground: false), .wait(PreviewAttachGate.interruptedReason))
        XCTAssertEqual(puerta.session(interrupted: false), .attach)
        XCTAssertEqual(puerta.session(interrupted: true), .nothing)
    }

    func testStateChangesWithoutARequestDoNothing() {
        var puerta = PreviewAttachGate()
        XCTAssertEqual(puerta.app(inBackground: true), .nothing)
        XCTAssertEqual(puerta.app(inBackground: false), .nothing)
        XCTAssertEqual(puerta.session(interrupted: false), .nothing)
        XCTAssertFalse(puerta.attached)
        XCTAssertFalse(puerta.requested)
    }
}
