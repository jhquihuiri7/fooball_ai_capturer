// El bucle del director (IOS-37): la réplica dorada de ProgramDirector.steps y los
// modos del operador.

import Foundation
import RigCore
import XCTest

final class DirectorLoopTests: XCTestCase {
    private static let frameMs = 1000.0 / 30.0

    // MARK: - El dorado

    func testElDirectorDePuntaAPunta() throws {
        let documento = try Golden.loadDocument(named: "shot.json")
        var corridas = 0
        for caso in documento.cases where caso.fn == "ProgramDirector.steps" {
            corridas += 1
            if let fallo = Golden.mismatch(
                actual: try Self.replica(caso.inputs), expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridas, 1)
    }

    // MARK: - El reloj de rigMs

    func testElTickPorRigMsEsElPasoDeLaReferencia() throws {
        // Los mismos ciclos por `tick` (dt de los rigMs, la acción consumida en el
        // primer paso) y por `step` (la semántica de la referencia) dan la misma vista.
        let (porTick, porPaso) = (try Self.bucle(), try Self.bucle())
        let jugadores = Self.grupo(yaw: 0.35)
        _ = try porTick.tick(targetRigMs: 0)
        for k in 1...90 {
            if k % 4 == 0 {
                porTick.ingest(jugadores)
                try porPaso.step(jugadores, dtS: 0.032)
            } else {
                try porPaso.step([RigPlayerDetection](), dtS: 0.032)
            }
            _ = try porTick.tick(targetRigMs: Int64(32 * k))
        }
        XCTAssertEqual(porTick.view.yawRad, porPaso.view.yawRad, accuracy: 1e-12)
        XCTAssertEqual(porTick.view.hfovRad, porPaso.view.hfovRad, accuracy: 1e-12)
    }

    func testUnHuecoSeIntegraEnPasosDeRejilla() throws {
        // Ciclos de detección cada 4 fotogramas: por saltos de 4 de golpe o fotograma
        // a fotograma, el mismo recorrido.
        let (hueco, seguido) = (try Self.bucle(), try Self.bucle())
        let jugadores = Self.grupo(yaw: 0.4)
        _ = try hueco.tick(targetRigMs: 0)
        _ = try seguido.tick(targetRigMs: 0)
        var fotograma = 0
        for _ in 0..<60 {
            hueco.ingest(jugadores)
            seguido.ingest(jugadores)
            for _ in 0..<4 {
                fotograma += 1
                _ = try seguido.tick(targetRigMs: Int64((Double(fotograma) * Self.frameMs).rounded()))
            }
            _ = try hueco.tick(targetRigMs: Int64((Double(fotograma) * Self.frameMs).rounded()))
        }
        XCTAssertEqual(hueco.view.yawRad, seguido.view.yawRad, accuracy: 1e-3)
        XCTAssertGreaterThan(hueco.view.yawRad, Self.centroYaw(hueco) + 0.1, "se movió hacia el grupo")
    }

    func testElViewCommandLlevaElContrato() throws {
        let director = try Self.bucle()
        let primero = try director.tick(targetRigMs: 1_000)
        let repetido = try director.tick(targetRigMs: 1_000)  // sin avance: misma vista
        XCTAssertEqual(primero.targetRigMs, 1_000)
        XCTAssertEqual(repetido.viewId, primero.viewId &+ 1)
        XCTAssertEqual(repetido.yawRad, primero.yawRad)
        XCTAssertEqual(primero.featherRad, RigConstants.panoramaFeatherRad)
        XCTAssertEqual(primero.gains, .unity)
        // El plano abierto del arranque cubre la costura: pintan las dos.
        XCTAssertEqual(primero.sides, [.left, .right])
    }

    // MARK: - Los modos del operador

    func testLaIaApagadaVuelveDespacioAlAbierto() throws {
        let director = try Self.bucle()
        var t: Int64 = 0
        _ = try director.tick(targetRigMs: t)
        for _ in 0..<300 {  // diez segundos cerrando sobre un grupo
            director.ingest(Self.grupo(yaw: 0.6))
            t += 33
            _ = try director.tick(targetRigMs: t)
        }
        let cerrado = director.view.hfovRad
        XCTAssertLessThan(cerrado, director.limits.hfovHigh)

        director.aiEnabled = false
        director.ingest(Self.grupo(yaw: 0.6))  // se ignora
        t += 33
        let siguiente = try director.tick(targetRigMs: t)
        XCTAssertLessThan(siguiente.hfovRad - cerrado, 0.05, "despacio: sin salto")
        for _ in 0..<600 {
            t += 33
            _ = try director.tick(targetRigMs: t)
        }
        XCTAssertEqual(director.view.hfovRad, director.limits.hfovHigh, accuracy: 0.05)
        XCTAssertEqual(director.view.yawRad, Self.centroYaw(director), accuracy: 0.05)
    }

    func testLaVistaManualManda() throws {
        let director = try Self.bucle()
        let pedido = RigDirection(yawRad: -0.3, pitchRad: -0.2)
        director.mode = .manual(pedido, hfovRad: director.limits.hfovLow)
        var t: Int64 = 0
        _ = try director.tick(targetRigMs: t)
        for _ in 0..<600 {
            director.ingest(Self.grupo(yaw: 0.6))  // la IA no la mueve
            t += 33
            _ = try director.tick(targetRigMs: t)
        }
        XCTAssertEqual(director.view.hfovRad, director.limits.hfovLow, accuracy: 0.05)
        XCTAssertEqual(director.view.yawRad, pedido.yawRad, accuracy: 0.08)
    }

    func testUnaLenteRecortaLaCoberturaYLosLados() throws {
        let director = try Self.bucle()
        let ambas = director.limits
        try director.setSingleLens(.right)
        XCTAssertGreaterThan(director.limits.yawLow, ambas.yawLow)
        let orden = try director.tick(targetRigMs: 0)
        XCTAssertEqual(orden.sides, [.right])
        try director.setSingleLens(nil)
        XCTAssertEqual(director.limits, ambas)
    }

    func testElGolPidePlanoDeSituacion() throws {
        let director = try Self.bucle()
        var t: Int64 = 0
        _ = try director.tick(targetRigMs: t)
        for _ in 0..<300 {
            director.ingest(Self.grupo(yaw: 0.2))
            t += 33
            _ = try director.tick(targetRigMs: t)
        }
        XCTAssertNotEqual(director.shot?.shot, .wide)
        director.markSituation()
        // Urgente, pero abrir también pide su insistencia: dentro del plano de
        // situación tiene que llegar al abierto.
        var abrio = false
        for _ in 0..<Int((RigConstants.shotSituationS * 1000 / 33).rounded(.down)) {
            director.ingest(Self.grupo(yaw: 0.2))
            t += 33
            _ = try director.tick(targetRigMs: t)
            if director.shot?.shot == .wide && director.shot?.reason == "situación" {
                abrio = true
            }
        }
        XCTAssertTrue(abrio)
    }

    // MARK: - La fusión de cajas

    func testLaFusionSeQuedaLaCajaDeQuienMejorLaVio() throws {
        let rig = try Self.soporte()
        let direccion = RigDirection(yawRad: 0, pitchRad: -0.14)
        let pi = rig.project(.left, direction: direccion)!
        let pd = rig.project(.right, direction: direccion)!
        func caja(_ p: (x: Double, y: Double), _ clase: PlayerClass, _ score: Double) -> PlayerDetection {
            PlayerDetection(x1: p.x - 20, y1: p.y - 120, x2: p.x + 20, y2: p.y, playerClass: clase, score: score)
        }
        let fundidas = rig.fusePlayers(
            left: [caja(pi, .goalkeeper, 0.6)], right: [caja(pd, .player, 0.9)]
        )
        XCTAssertEqual(fundidas.count, 1)
        XCTAssertEqual(fundidas[0].side, .right)
        XCTAssertEqual(fundidas[0].playerClass, .player)
        XCTAssertEqual(fundidas[0].sides, [.left, .right])
        // A igual score gana la izquierda, como `max` de Python.
        let empate = rig.fusePlayers(left: [caja(pi, .goalkeeper, 0.7)], right: [caja(pd, .player, 0.7)])
        XCTAssertEqual(empate[0].side, .left)
    }

    // MARK: - Soporte

    private static func soporte() throws -> RigModel {
        try RigModel.load(
            from: Bundle.module.url(forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures")!
        )
    }

    private static func bucle() throws -> DirectorLoop {
        let rig = try soporte()
        return try DirectorLoop(
            rig: rig,
            canvas: CylindricalCanvas.fit(rig, pitchLimitsRad: (-0.5, 0.1)),
            // 720p: a 1920 la lente del pod no sirve nada más cerrado que lo que cabe
            // y no habría zoom que probar.
            width: 1280,
            height: 720,
            plan: ShotPlan.at(),
            frameDurationMs: frameMs
        )
    }

    private static func centroYaw(_ director: DirectorLoop) -> Double {
        (director.limits.yawLow + director.limits.yawHigh) / 2
    }

    /// Diez jugadores apretados alrededor de un yaw: juego concentrado.
    private static func grupo(yaw: Double) -> [RigPlayerDetection] {
        (0..<10).map { i in
            RigPlayerDetection(
                direction: RigDirection(yawRad: yaw + 0.01 * Double(i - 5), pitchRad: -0.15),
                detection: PlayerDetection(x1: 0, y1: 0, x2: 0, y2: 0, playerClass: .player, score: 0.9),
                side: .left,
                sides: [.left]
            )
        }
    }

    private static func replica(_ inputs: GoldenValue) throws -> GoldenValue {
        guard let rigCrudo = try inputs.field("rig").jsonObject() as? [String: Any] else {
            throw GoldenError.message("rig no es un objeto")
        }
        let c = try inputs.field("canvas")
        let p = try inputs.field("plan")
        guard let crudos = try p.field("hfov_rad").objectValue else {
            throw GoldenError.message("hfov_rad no es un objeto")
        }
        var hfov: [ShotSize: Double] = [:]
        for (nombre, valor) in crudos {
            hfov[ShotSize(rawValue: nombre)!] = valor.numberValue
        }
        let director = try DirectorLoop(
            rig: RigModel.fromDictionary(rigCrudo),
            canvas: CylindricalCanvas(
                focalPx: c.number("focal_px"),
                yawMinRad: c.number("yaw_min_rad"),
                yawMaxRad: c.number("yaw_max_rad"),
                pitchMinRad: c.number("pitch_min_rad"),
                pitchMaxRad: c.number("pitch_max_rad")
            ),
            width: Int(inputs.number("width")),
            height: Int(inputs.number("height")),
            plan: ShotPlan(hfovRad: hfov, tightRad: p.number("tight_rad"), stretchedRad: p.number("stretched_rad")),
            frameDurationMs: frameMs
        )
        guard case let .array(pasos)? = try? inputs.field("detections_per_step") else {
            throw GoldenError.message("detections_per_step no es una lista")
        }
        let dt = try inputs.number("dt_s")
        var yaw: [Double] = []
        var pitch: [Double] = []
        var anchos: [Double] = []
        var planos: [GoldenValue] = []
        for paso in pasos {
            guard case let .array(detecciones) = paso else {
                throw GoldenError.message("un paso no es una lista")
            }
            let avistamientos = try detecciones.map { d in
                RigPlayerDetection(
                    direction: RigDirection(yawRad: try d.number("yaw_rad"), pitchRad: try d.number("pitch_rad")),
                    detection: PlayerDetection(
                        x1: 0, y1: 0, x2: 0, y2: 0,
                        playerClass: PlayerClass(rawValue: try d.string("cls"))!,
                        score: try d.number("score")
                    ),
                    side: .left,
                    sides: [.left]
                )
            }
            let vista = try director.step(avistamientos, dtS: dt)
            yaw.append(vista.yawRad)
            pitch.append(vista.pitchRad)
            anchos.append(vista.hfovRad)
            planos.append(.string(director.shot?.shot.rawValue ?? ""))
        }
        let n = yaw.count
        return .object([
            "yaw_rad": .tensor(f64: yaw, shape: [n]),
            "pitch_rad": .tensor(f64: pitch, shape: [n]),
            "hfov_rad": .tensor(f64: anchos, shape: [n]),
            "shot": .array(planos),
        ])
    }
}
