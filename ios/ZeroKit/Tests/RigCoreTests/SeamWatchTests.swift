// La vigilancia de la costura (IOS-72): con la pose de una cámara movida 0,5°, el
// aviso sale en ≤60 s; con la calibración bien, no sale.

import Foundation
import RigCore
import XCTest

final class SeamWatchTests: XCTestCase {
    private static let hzDeteccion = 7.5
    private static let jugadoresPorCiclo = 4
    private static let ruidoPx = 1.0

    func testConLaPoseMovidaMedioGradoAvisaEnUnMinuto() throws {
        let (segundos, _) = try Self.segundosHastaElAviso(perturbacionGrados: 0.5, limiteS: 120)
        let s = try XCTUnwrap(segundos, "no avisó en dos minutos")
        XCTAssertLessThanOrEqual(s, 60)
    }

    func testConLaCalibracionBienNoAvisa() throws {
        let (segundos, mediana) = try Self.segundosHastaElAviso(perturbacionGrados: 0, limiteS: 120)
        XCTAssertNil(segundos)
        // Y no por falta de parejas: hubo mediana, y es la del paralaje y el ruido.
        let m = try XCTUnwrap(mediana, "ninguna pareja se fundió")
        XCTAssertLessThan(m, RigConstants.rigSeamWatchMaxMedianRad / 2)
    }

    func testSinMuestrasSuficientesNoOpina() {
        let watch = SeamWatch(maxMedianRad: 0.01, window: 8, minSamples: 4)
        watch.observe(Self.parejas([0.5, 0.5, 0.5]))
        XCTAssertNil(watch.medianRad)
        XCTAssertFalse(watch.suggestsRecalibration)
        watch.observe(Self.parejas([0.5]))
        XCTAssertEqual(watch.medianRad, 0.5)
        XCTAssertTrue(watch.suggestsRecalibration)
        watch.reset()
        XCTAssertNil(watch.medianRad)
    }

    func testLaVentanaOlvidaLoViejoYSoloCuentanLasParejas() {
        let watch = SeamWatch(maxMedianRad: 0.01, window: 4, minSamples: 2)
        watch.observe(Self.parejas([1, 1, 1, 1]))
        watch.observe(Self.parejas([0.001, 0.002, 0.003]))
        // Una detección de una sola cámara no tiene separación: no cuenta.
        watch.observe([RigPlayerDetection(
            direction: RigDirection(yawRad: 0, pitchRad: 0),
            detection: PlayerDetection(x1: 0, y1: 0, x2: 1, y2: 1, playerClass: .player, score: 1),
            side: .left, sides: [.left], separationRad: 9
        )])
        XCTAssertEqual(try XCTUnwrap(watch.medianRad), (0.002 + 0.003) / 2, accuracy: 1e-12)
    }

    // MARK: - La réplica

    /// Simula la detección a 7,5 Hz con la pose derecha VERDADERA movida y la
    /// calibración sin mover, y devuelve cuándo avisa (o nil si no avisa).
    private static func segundosHastaElAviso(
        perturbacionGrados: Double, limiteS: Double
    ) throws -> (segundos: Double?, mediana: Double?) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures"))
        let calibrado = try RigModel.load(from: url)
        let derecha = calibrado.camera(.right).pose
        let verdad = try calibrado.withPose(.right, pose: CameraPose(
            yawRad: derecha.yawRad + perturbacionGrados * .pi / 180,
            pitchRad: derecha.pitchRad, rollRad: derecha.rollRad
        ))
        let watch = SeamWatch()
        var semilla: UInt64 = 0x5EA_17A7C
        func azar() -> Double {
            semilla = semilla &* 6364136223846793005 &+ 1442695040888963407
            return Double(semilla >> 11) / Double(1 << 53)
        }
        let ciclos = Int(limiteS * hzDeteccion)
        for ciclo in 0..<ciclos {
            var izquierda: [PlayerDetection] = []
            var derechaCajas: [PlayerDetection] = []
            for _ in 0..<jugadoresPorCiclo {
                // Un pie en el solape, entre el centro y la línea de fondo lejana.
                let direccion = RigDirection(yawRad: (azar() - 0.5) * 0.3, pitchRad: -0.05 - azar() * 0.25)
                guard verdad.inOverlap(direccion),
                      let pi = verdad.project(.left, direction: direccion),
                      let pd = verdad.project(.right, direction: direccion)
                else { continue }
                func caja(_ p: (x: Double, y: Double)) -> PlayerDetection {
                    let x = p.x + (azar() - 0.5) * 2 * ruidoPx, y = p.y + (azar() - 0.5) * 2 * ruidoPx
                    return PlayerDetection(x1: x - 15, y1: y - 80, x2: x + 15, y2: y, playerClass: .player, score: 0.9)
                }
                izquierda.append(caja(pi))
                derechaCajas.append(caja(pd))
            }
            watch.observe(calibrado.fusePlayers(left: izquierda, right: derechaCajas))
            if watch.suggestsRecalibration {
                return (Double(ciclo + 1) / hzDeteccion, watch.medianRad)
            }
        }
        return (nil, watch.medianRad)
    }

    private static func parejas(_ separaciones: [Double]) -> [RigPlayerDetection] {
        separaciones.map {
            RigPlayerDetection(
                direction: RigDirection(yawRad: 0, pitchRad: 0),
                detection: PlayerDetection(x1: 0, y1: 0, x2: 1, y2: 1, playerClass: .player, score: 1),
                side: .left, sides: [.left, .right], separationRad: $0
            )
        }
    }
}
