// La homografía coincide con la proyección píxel a píxel (IOS-31).

import Foundation
import RigCore
import XCTest

final class ViewHomographyTests: XCTestCase {
    private func soporte() throws -> RigModel {
        let url = Bundle.module.url(
            forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures"
        )!
        return try RigModel.load(from: url)
    }

    func testVeinteVistasCoincidenConLaProyeccionEnRejilla() throws {
        // La aceptación: por cada vista y lado, H·(x,y,1) tiene que dar el MISMO
        // píxel que project(directionAt(x,y)) en toda una rejilla del programa.
        let rig = try soporte()
        var contadas = 0  // las vistas van con paso fijo, no al azar: determinismo
        for indice in 0..<20 {
            let yaw = -0.5 + Double(indice) * 0.05
            let pitch = -0.25 + Double(indice % 5) * 0.04
            let hfov = 0.4 + Double(indice % 7) * 0.08
            let vista = try RectilinearView(
                yawRad: yaw, pitchRad: pitch, hfovRad: hfov, width: 1920, height: 1080
            )
            for side in CameraSide.allCases {
                let h = viewHomography(rig: rig, view: vista, side: side)
                for x in stride(from: 0.0, through: 1919.0, by: 383.8) {
                    for y in stride(from: 0.0, through: 1079.0, by: 359.6667) {
                        let homogeneo = h.applied(to: Vec3(x, y, 1))
                        guard homogeneo.z > 0 else { continue }
                        guard let pixel = rig.project(
                            side, direction: vista.directionAt(xPx: x, yPx: y)
                        ) else { continue }
                        XCTAssertEqual(homogeneo.x / homogeneo.z, pixel.x, accuracy: 1e-6)
                        XCTAssertEqual(homogeneo.y / homogeneo.z, pixel.y, accuracy: 1e-6)
                        contadas += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(contadas, 400, "la rejilla apenas cayó delante de las cámaras")
    }

    func testLaHomografiaAlBuferCrudoPasaPorLaMontura() throws {
        let rig = try soporte()
        let vista = try RectilinearView(
            yawRad: -0.6, pitchRad: -0.14, hfovRad: 0.9, width: 1920, height: 1080
        )
        let h = viewHomography(rig: rig, view: vista, side: .left)
        let hCruda = viewHomographyToRaw(rig: rig, view: vista, side: .left)
        let intr = rig.camera(.left).intrinsics

        let enderezado = h.applied(to: Vec3(960, 540, 1))
        let crudo = hCruda.applied(to: Vec3(960, 540, 1))
        let esperado = CameraMount.uprightPoint(
            x: enderezado.x / enderezado.z,
            y: enderezado.y / enderezado.z,
            width: intr.width,
            height: intr.height
        )
        XCTAssertEqual(crudo.x / crudo.z, esperado.x, accuracy: 1e-9)
        XCTAssertEqual(crudo.y / crudo.z, esperado.y, accuracy: 1e-9)
    }
}
