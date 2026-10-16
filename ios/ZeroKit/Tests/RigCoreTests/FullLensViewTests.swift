// «Una cámara» tal cual (ADR 0025, enmienda del 2026-10-15): la vista de la lente entera.

import Foundation
import RigCore
import XCTest

final class FullLensViewTests: XCTestCase {
    /// La ultra gran angular a 4K: 106° de horizontal, centro óptico en el centro.
    private static func lente(roll: Double, yaw: Double = -0.7, pitch: Double = -0.17) throws -> RigCamera {
        let fx = 1920 / tan(106 * Double.pi / 360)
        return RigCamera(
            intrinsics: try CameraIntrinsics(fx: fx, fy: fx, cx: 1919.5, cy: 1079.5, width: 3840, height: 2160),
            pose: CameraPose(yawRad: yaw, pitchRad: pitch, rollRad: roll)
        )
    }

    private static func soporte(roll: Double) throws -> RigModel {
        RigModel(left: try lente(roll: roll), right: try lente(roll: 0, yaw: 0.7))
    }

    /// Las cuatro esquinas del programa, proyectadas en la imagen de la lente.
    private static func esquinas(_ rig: RigModel, _ vista: RectilinearView) -> [(x: Double, y: Double)?] {
        let w = Double(vista.width), h = Double(vista.height)
        return [(-0.5, -0.5), (w - 0.5, -0.5), (-0.5, h - 0.5), (w - 0.5, h - 0.5)].map { x, y in
            rig.project(.left, direction: vista.directionAt(xPx: x, yPx: y))
        }
    }

    private static func dentro(_ p: (x: Double, y: Double)?) -> Bool {
        guard let p else { return false }
        return p.x >= -0.5 && p.x <= 3839.5 && p.y >= -0.5 && p.y <= 2159.5
    }

    func testSinGiroEsLaLenteEnteraMenosElMargen() throws {
        let camara = try Self.lente(roll: 0)
        let hfov = FullLensView.hfovRad(of: camara, width: 1920, height: 1080)
        XCTAssertEqual(tan(hfov / 2), tan(106 * Double.pi / 360) * FullLensView.fillFraction, accuracy: 1e-9)
    }

    func testMiraHaciaDondeMiraLaCamara() throws {
        let rig = try Self.soporte(roll: 0.05)
        let vista = try FullLensView.view(rig: rig, side: .left, width: 1920, height: 1080)
        XCTAssertEqual(vista.yawRad, rig.camera(.left).pose.yawRad)
        XCTAssertEqual(vista.pitchRad, rig.camera(.left).pose.pitchRad)
        XCTAssertEqual((vista.width, vista.height), (1920, 1080))
    }

    func testNingunaEsquinaSeSaleDeLaLenteAunqueElMovilVayaGirado() throws {
        for roll in [0.0, 0.03, -0.05, 0.12] {
            let rig = try Self.soporte(roll: roll)
            let vista = try FullLensView.view(rig: rig, side: .left, width: 1920, height: 1080)
            for (i, p) in Self.esquinas(rig, vista).enumerated() {
                XCTAssertTrue(Self.dentro(p), "roll \(roll), esquina \(i): \(String(describing: p))")
            }
        }
    }

    func testEsLaMasAnchaQueCabe() throws {
        // Un 2 % más abierta que la que sale (el doble del margen), alguna esquina ya cae fuera.
        for roll in [0.0, 0.12] {
            let rig = try Self.soporte(roll: roll)
            let vista = try FullLensView.view(rig: rig, side: .left, width: 1920, height: 1080)
            let tanMayor = tan(vista.hfovRad / 2) / FullLensView.fillFraction * 1.01
            let mayor = try vista.withHfov(2 * atan(tanMayor))
            XCTAssertFalse(Self.esquinas(rig, mayor).allSatisfy(Self.dentro), "roll \(roll)")
        }
    }
}
