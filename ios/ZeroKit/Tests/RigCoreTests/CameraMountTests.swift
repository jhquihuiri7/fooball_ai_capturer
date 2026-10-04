// La montura del móvil invertido (IOS-30): el giro de 180° y su matriz F.

import RigCore
import XCTest

final class CameraMountTests: XCTestCase {
    func testElGiroEsInvolutivo() {
        let (x1, y1) = CameraMount.uprightPoint(x: 100.5, y: 200.25, width: 3840, height: 2160)
        let (x2, y2) = CameraMount.uprightPoint(x: x1, y: y1, width: 3840, height: 2160)
        XCTAssertEqual(x2, 100.5, accuracy: 0)
        XCTAssertEqual(y2, 200.25, accuracy: 0)
    }

    func testLasEsquinasSeIntercambian() {
        // El (0,0) del búfer crudo es la esquina opuesta de la imagen enderezada.
        let (x, y) = CameraMount.uprightPoint(x: 0, y: 0, width: 3840, height: 2160)
        XCTAssertEqual(x, 3839)
        XCTAssertEqual(y, 2159)
    }

    func testLaMatrizHaceLoMismoQueElPunto() {
        let f = CameraMount.uprightMatrix(width: 3840, height: 2160)
        let homogeneo = f.applied(to: Vec3(123.5, 456.25, 1.0))
        let (x, y) = CameraMount.uprightPoint(x: 123.5, y: 456.25, width: 3840, height: 2160)
        XCTAssertEqual(homogeneo.x / homogeneo.z, x, accuracy: 1e-12)
        XCTAssertEqual(homogeneo.y / homogeneo.z, y, accuracy: 1e-12)
        // Involutiva también como matriz: F·F = identidad.
        XCTAssertEqual(f.multiplied(by: f), Mat3.identity)
    }
}
