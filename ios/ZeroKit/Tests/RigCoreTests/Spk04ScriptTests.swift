// El director de guion de SPK-04: determinista en el reloj del soporte, cruza la costura
// cada 20 s y abre el zoom de 40° a 83°.

import Foundation
import RigCore
import XCTest

final class Spk04ScriptTests: XCTestCase {
    private let grados = 180 / Double.pi

    private func soporte(yawDeg: Double = 42, pitchDeg: Double = -10) throws -> RigModel {
        let intr = try CameraIntrinsics.fromHfov(width: 3840, height: 2160, hfovRad: 106 / grados)
        return RigModel(
            left: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: -yawDeg / grados, pitchRad: pitchDeg / grados)),
            right: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: yawDeg / grados, pitchRad: (pitchDeg - 2) / grados))
        )
    }

    func testCruzaLaCosturaCada20Segundos() throws {
        let guion = Spk04Script(rig: try soporte())
        XCTAssertEqual(guion.seamYawRad, 0, accuracy: 1e-12)
        XCTAssertEqual(guion.pitchRad * grados, -11, accuracy: 1e-9)
        // Los cruces, de 10 en 10 ms durante 2 min: uno cada 20 s, ni uno más.
        var cruces: [Int64] = []
        var previo = guion.pose(atRigMs: 0).yawRad
        for t in stride(from: Int64(10), through: 120_000, by: 10) {
            let yaw = guion.pose(atRigMs: t).yawRad
            if (previo < 0) != (yaw < 0) { cruces.append(t) }
            previo = yaw
        }
        XCTAssertEqual(cruces.count, 6)
        for (i, c) in cruces.enumerated() {
            XCTAssertEqual(Double(c), Double(i + 1) * 20_000, accuracy: 10)
        }
        let yaws = stride(from: Int64(0), to: 40_000, by: 100).map { guion.pose(atRigMs: $0).yawRad * grados }
        XCTAssertEqual(yaws.max()!, Spk04Script.sweepAmplitudeDeg, accuracy: 0.01)
        XCTAssertEqual(yaws.min()!, -Spk04Script.sweepAmplitudeDeg, accuracy: 0.01)
    }

    func testElZoomVaDe40A83() throws {
        let guion = Spk04Script(seamYawRad: 0, pitchRad: 0)
        let hfovs = stride(from: Int64(0), to: 60_000, by: 50).map { guion.pose(atRigMs: $0).hfovRad * grados }
        XCTAssertEqual(hfovs.min()!, 40, accuracy: 0.01)
        XCTAssertEqual(hfovs.max()!, 83, accuracy: 0.05)
        XCTAssertEqual(guion.pose(atRigMs: 30_000).hfovRad * grados, 83, accuracy: 1e-9)
        XCTAssertEqual(guion.pose(atRigMs: 15_000).hfovRad * grados, 61.5, accuracy: 1e-9)
    }

    func testDeterministaConElInstanteDelSoporteYSinArranque() {
        let a = Spk04Script(seamYawRad: 0.01, pitchRad: -0.2)
        let b = Spk04Script(seamYawRad: 0.01, pitchRad: -0.2)
        // Un rigMs de días: la fase sale del módulo entero y se repite cada 120 s.
        let t: Int64 = 3 * 86_400_000 + 12_345
        XCTAssertEqual(a.pose(atRigMs: t).yawRad, b.pose(atRigMs: t).yawRad)
        XCTAssertEqual(a.pose(atRigMs: t).yawRad, a.pose(atRigMs: t + 120_000).yawRad, accuracy: 1e-12)
        XCTAssertEqual(a.pose(atRigMs: t).hfovRad, a.pose(atRigMs: t + 120_000).hfovRad, accuracy: 1e-12)
        XCTAssertEqual(a.pose(atRigMs: -5_000).yawRad, a.pose(atRigMs: 115_000).yawRad, accuracy: 1e-12)
    }

    func testHayPlanosDeUnaLenteACadaLadoYDeDos() throws {
        let rig = try soporte()
        let guion = Spk04Script(rig: rig)
        var lados: Set<[CameraSide]> = []
        for t in stride(from: Int64(0), to: 120_000, by: 250) {
            let p = guion.pose(atRigMs: t)
            let v = try RectilinearView(yawRad: p.yawRad, pitchRad: guion.pitchRad, hfovRad: p.hfovRad,
                                        width: 1920, height: 1080)
            lados.insert(sidesFor(rig: rig, view: v))
        }
        XCTAssertEqual(lados, [[.left], [.right], [.left, .right]])
    }
}
