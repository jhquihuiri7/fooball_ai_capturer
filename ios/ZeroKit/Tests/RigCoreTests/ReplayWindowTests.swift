import XCTest

@testable import RigCore

/// La ventana de 64 del canal de medios (IOS-16): desorden sí, repetición no.
final class ReplayWindowTests: XCTestCase {
    func testOutOfOrderWithinTheWindowIsAccepted() {
        var ventana = ReplayWindow()
        XCTAssertTrue(ventana.accept(10))
        XCTAssertTrue(ventana.accept(12))
        XCTAssertTrue(ventana.accept(11))  // desordenado, dentro de la ventana
        XCTAssertEqual(ventana.accepted, 3)
    }

    func testADuplicateIsRejected() {
        var ventana = ReplayWindow()
        XCTAssertTrue(ventana.accept(5))
        XCTAssertFalse(ventana.accept(5))
        XCTAssertEqual(ventana.rejectedDuplicate, 1)
    }

    func testAnythingBehindTheWindowIsRejected() {
        var ventana = ReplayWindow(span: 64)
        XCTAssertTrue(ventana.accept(100))
        XCTAssertTrue(ventana.accept(37))   // 100 − 63: justo dentro
        XCTAssertFalse(ventana.accept(36))  // 100 − 64: ya fuera
        XCTAssertEqual(ventana.rejectedOld, 1)
    }

    func testABigJumpForwardResetsTheWindow() {
        var ventana = ReplayWindow()
        XCTAssertTrue(ventana.accept(1))
        XCTAssertTrue(ventana.accept(1000))
        XCTAssertFalse(ventana.accept(1))    // quedó muy atrás
        XCTAssertTrue(ventana.accept(999))   // dentro de la ventana nueva
    }
}
