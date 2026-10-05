import XCTest

import RigCore
@testable import RigMedia

/// El director en vivo del maestro (IOS-73) con detecciones «grabadas»: un grupo de
/// jugadores que el detector ve en la cámara derecha y que el director tiene que seguir.
final class DirectorServiceTests: XCTestCase {
    private func soporte() throws -> RigModel {
        let intr = try CameraIntrinsics.fromHfov(width: 1920, height: 1080, hfovRad: 106 * .pi / 180)
        let yaw = RigConstants.defaultRigYawDeg * .pi / 180
        let pitch = RigConstants.defaultRigPitchDeg * .pi / 180
        return RigModel(
            left: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: -yaw, pitchRad: pitch)),
            right: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: yaw, pitchRad: pitch))
        )
    }

    /// Las cajas que daría el detector de una cámara para jugadores en estas direcciones.
    private func cajas(_ rig: RigModel, _ side: CameraSide, _ dirs: [RigDirection]) -> [PlayerDetection] {
        dirs.compactMap { d in
            guard let (x, y) = rig.project(side, direction: d) else { return nil }
            return PlayerDetection(x1: x - 10, y1: y - 60, x2: x + 10, y2: y, playerClass: .player, score: 0.9)
        }
    }

    func testSigueAlGrupoYEmparejaPorInstante() throws {
        let rig = try soporte()
        let loop = try DirectorLoop(
            rig: rig, canvas: CylindricalCanvas.fit(rig, pitchLimitsRad: (-0.5, 0.1)),
            width: 1280, height: 720, plan: ShotPlan.at(), frameDurationMs: 1000.0 / 30
        )
        let director = DirectorService(loop: loop)
        let cadencia = DetectionCadence()
        let grupo = (0..<10).map { RigDirection(yawRad: 0.45 + 0.01 * Double($0 - 5), pitchRad: -0.2) }
        let inicio = try director.tick(targetRigMs: 0).view.yawRad
        var ultimo = inicio
        var k: Int64 = 1
        for n in 1...(30 * 15) {
            let t = Int64((Double(n) * 1000 / 30).rounded())
            while cadencia.instant(k) <= t {
                let tk = cadencia.instant(k)
                // Los dos móviles mandan su ciclo; el izquierdo no ve al grupo.
                director.receive(side: .right, targetRigMs: tk, detections: cajas(rig, .right, grupo))
                director.receive(side: .left, targetRigMs: tk, detections: cajas(rig, .left, grupo))
                k += 1
            }
            let (v, hist) = try director.tick(targetRigMs: t)
            XCTAssertEqual(v.targetRigMs, t)
            XCTAssertLessThanOrEqual(hist.count, LinkConstants.viewHistory)
            ultimo = v.yawRad
        }
        XCTAssertGreaterThan(ultimo, inicio + 0.2, "la cámara virtual va hacia el grupo")
        XCTAssertEqual(ultimo, 0.45, accuracy: 0.15)
        XCTAssertEqual(director.pairing.complete, Int(k - 1), "todas las parejas, con desfase cero")
        XCTAssertEqual(director.pairing.maxAbsSkewNs, 0)
        XCTAssertEqual(director.cyclesIngested, Int(k - 1))
    }

    func testSoloUnaCamaraSigueDirigiendoYPlanoAbiertoSeQuedaQuieto() throws {
        let rig = try soporte()
        let loop = try DirectorLoop(
            rig: rig, canvas: CylindricalCanvas.fit(rig, pitchLimitsRad: (-0.5, 0.1)),
            width: 1280, height: 720, plan: ShotPlan.at(), frameDurationMs: 1000.0 / 30
        )
        let director = DirectorService(loop: loop)
        director.setMode(.fixedWide)
        let quieto = try director.tick(targetRigMs: 0).view
        for k in 1...40 {
            director.receive(side: .right, targetRigMs: Int64(133 * k),
                             detections: cajas(rig, .right, [RigDirection(yawRad: 0.5, pitchRad: -0.2)]))
        }
        let luego = try director.tick(targetRigMs: 40 * 133).view
        XCTAssertEqual(luego.yawRad, quieto.yawRad, accuracy: 1e-6, "plano abierto: no persigue")
        XCTAssertGreaterThan(director.pairing.orphanRight, 30, "sin izquierda, huérfanos de la derecha")
    }
}
