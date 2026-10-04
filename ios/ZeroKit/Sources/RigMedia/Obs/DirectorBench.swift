// El banco del director (IOS-37): lo que cuesta el bucle del director por fotograma
// del programa en el iPhone (objetivo <0,2 ms).
//
// El soporte nominal del pod (4K, ±40°, el izquierdo cabeza abajo), un partido
// sintético con el guion del dorado de dos minutos de REF y las cajas proyectadas a
// las dos cámaras ANTES de medir: se mide solo el director —fusión de las dos cámaras,
// acción, plano y paso del motor—, no la generación del partido. Las muestras se
// guardan en crudo en un búfer reservado al empezar: los cubos del histograma son
// demasiado gruesos por debajo del milisegundo.

import Foundation
import RigCore

enum DirectorBench {
    /// Dos minutos de programa a 30 fps, como el dorado de REF.
    static let frames = 3600
    static let frameMs = 1000.0 / 30.0
    /// La detección corre a 7,5 Hz: un ciclo cada cuatro fotogramas.
    static let framesPerCycle = 4
    static let players = 12
    static let defaultRepetitions = 5

    static func run(report: inout BenchReport, progress: BenchRunner.Progress?) throws {
        let repeticiones = Int(report.params["repetitions"] ?? "") ?? defaultRepetitions
        let rig = try nominalRig()
        let canvas = try CylindricalCanvas.fit(rig, pitchLimitsRad: (-0.6, 0.2))
        let ciclos = try partido(rig)

        var porFotograma = [Double](repeating: 0, count: frames * repeticiones)
        var porCiclo = [Double](repeating: 0, count: (frames / framesPerCycle + 1) * repeticiones)
        var (n, m) = (0, 0)
        for r in 0..<repeticiones {
            let director = try DirectorLoop(
                rig: rig, canvas: canvas, width: 1920, height: 1080,
                plan: ShotPlan.at(), frameDurationMs: frameMs
            )
            for f in 0..<frames {
                let t0 = DispatchTime.now().uptimeNanoseconds
                if f % framesPerCycle == 0, let ciclo = ciclos[f / framesPerCycle] {
                    director.ingest(left: ciclo.left, right: ciclo.right)
                    porCiclo[m] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    m += 1
                }
                _ = try director.tick(targetRigMs: Int64((Double(f) * frameMs).rounded()))
                porFotograma[n] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                n += 1
            }
            progress?(Double(r + 1) / Double(repeticiones), "repetición \(r + 1) de \(repeticiones)")
        }
        report.stagesMs["director/frame"] = summary(Array(porFotograma[0..<n]))
        report.stagesMs["director/ingest"] = summary(Array(porCiclo[0..<m]))
        report.counters["frames"] = n
        report.counters["detection_cycles"] = m
        report.params["repetitions"] = "\(repeticiones)"
    }

    /// Percentiles exactos de las muestras crudas.
    static func summary(_ muestras: [Double]) -> BenchReport.StageSummary {
        let orden = muestras.sorted()
        func p(_ q: Double) -> Double {
            orden.isEmpty ? 0 : orden[min(orden.count - 1, Int((q * Double(orden.count)).rounded(.down)))]
        }
        return BenchReport.StageSummary(p50Ms: p(0.5), p90Ms: p(0.9), p99Ms: p(0.99))
    }

    /// El soporte nominal del pod: rig.json de soporte-pod.json.
    static func nominalRig() throws -> RigModel {
        let intr = try CameraIntrinsics.fromHfov(width: 3840, height: 2160, hfovRad: 106 * .pi / 180)
        let pitch = -8 * Double.pi / 180
        return RigModel(
            left: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: -40 * .pi / 180, pitchRad: pitch, rollRad: .pi)),
            right: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: 40 * .pi / 180, pitchRad: pitch, rollRad: 0))
        )
    }

    /// Los ciclos de detección del partido, ya proyectados a cajas de cada cámara.
    /// `nil` es un ciclo en el que el detector no entregó nada (el parón de 2 s).
    static func partido(_ rig: RigModel) throws -> [(left: [PlayerDetection], right: [PlayerDetection])?] {
        var ciclos: [(left: [PlayerDetection], right: [PlayerDetection])?] = []
        for f in stride(from: 0, to: frames, by: framesPerCycle) {
            let t = Double(f) * frameMs / 1000
            if t >= 80 && t < 82 {
                ciclos.append(nil)
                continue
            }
            let fase = Int(t / 20), avance = t.truncatingRemainder(dividingBy: 20) / 20
            var izquierda: [PlayerDetection] = [], derecha: [PlayerDetection] = []
            for i in 0..<players {
                let base = 0.07 * sin(Double(i) * 1.7 + t * 0.3)
                let yaw: Double
                switch fase {
                case 0: yaw = -0.5 + avance + base
                case 1: yaw = 0.5 - 0.4 * avance + (Double(i) - Double(players) / 2) * 0.09
                case 2: yaw = (i % 2 == 1 ? -0.45 : 0.4) + base
                case 3: yaw = 0.1 * sin(t * 0.4) + base
                case 4: yaw = -0.2 + 0.6 * avance + base
                default: yaw = 0.6 + 0.4 * base
                }
                let direccion = RigDirection(yawRad: yaw, pitchRad: -0.14 + 0.03 * cos(Double(i) * 1.3 + t * 0.2))
                let clase: PlayerClass = i == 0 ? .goalkeeper : (i == players - 1 ? .referee : .player)
                let score = 0.55 + 0.03 * Double((i * 7 + f) % 13)
                for (lado, lista) in [(CameraSide.left, 0), (.right, 1)] {
                    guard rig.sees(lado, direction: direccion), let p = rig.project(lado, direction: direccion) else { continue }
                    let caja = PlayerDetection(x1: p.x - 20, y1: p.y - 110, x2: p.x + 20, y2: p.y, playerClass: clase, score: score)
                    if lista == 0 { izquierda.append(caja) } else { derecha.append(caja) }
                }
            }
            ciclos.append((izquierda, derecha))
        }
        return ciclos
    }
}
