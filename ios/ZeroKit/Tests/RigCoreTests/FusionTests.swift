// La fusión angular, pieza a pieza (IOS-32). Los dorados de fuse viven en
// RigModelTests; aquí van las propiedades que un dorado no nombra solo.

import Foundation
import RigCore
import XCTest

final class FusionTests: XCTestCase {
    private func soporte() throws -> RigModel {
        let url = Bundle.module.url(
            forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures"
        )!
        return try RigModel.load(from: url)
    }

    func testNoFundeDentroDeLaMismaCamara() throws {
        let rig = try soporte()
        // Dos detecciones casi en el mismo sitio de la MISMA cámara: dos objetos.
        let fundidas = rig.fuse(
            [
                Observation(side: .left, xPx: 2000, yPx: 1200, score: 0.9, key: 1),
                Observation(side: .left, xPx: 2004, yPx: 1200, score: 0.8, key: 2),
            ],
            maxAngleRad: 0.05
        )
        XCTAssertEqual(fundidas.count, 2)
        XCTAssertTrue(fundidas.allSatisfy { $0.sides == [.left] })
    }

    func testElVorazRespetaElScoreYDevuelveLasClaves() throws {
        let rig = try soporte()
        // Una dirección del solape, proyectada a los DOS lados: la misma persona.
        let direccion = RigDirection(yawRad: 0, pitchRad: -0.14)
        XCTAssertTrue(rig.inOverlap(direccion))
        guard let enIzquierda = rig.project(.left, direction: direccion),
              let enDerecha = rig.project(.right, direction: direccion)
        else {
            return XCTFail("la dirección del solape no proyecta en ambas")
        }
        let fundidas = rig.fuse(
            [
                Observation(side: .left, xPx: enIzquierda.x, yPx: enIzquierda.y, score: 0.9, key: 7),
                Observation(side: .right, xPx: enDerecha.x, yPx: enDerecha.y, score: 0.6, key: 9),
            ],
            maxAngleRad: 0.02
        )
        XCTAssertEqual(fundidas.count, 1)
        XCTAssertEqual(fundidas[0].sides, [.left, .right])
        XCTAssertEqual(fundidas[0].keys, [7, 9])
        XCTAssertEqual(fundidas[0].score, 0.9)  // el mejor de los dos, nunca la media
        XCTAssertLessThan(fundidas[0].separationRad, 1e-6)  // acos amplifica cerca de 1
    }

    func testElOrdenDeSalidaEsPorScoreDescendente() throws {
        let rig = try soporte()
        let fundidas = rig.fuse(
            [
                Observation(side: .left, xPx: 1000, yPx: 1000, score: 0.3, key: 1),
                Observation(side: .left, xPx: 2000, yPx: 1000, score: 0.8, key: 2),
                Observation(side: .right, xPx: 2000, yPx: 1000, score: 0.5, key: 3),
            ],
            maxAngleRad: 1e-6
        )
        XCTAssertEqual(fundidas.map(\.score), [0.8, 0.5, 0.3])
    }
}
