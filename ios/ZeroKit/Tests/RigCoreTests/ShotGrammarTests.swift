// La gramática de planos contra la secuencia dorada de shot.json (IOS-35): mismos
// planos, mismos cambios y mismas razones, ciclo a ciclo.

import Foundation
import RigCore
import XCTest

final class ShotGrammarTests: XCTestCase {
    func testLaSecuenciaDorada() throws {
        let documento = try Golden.loadDocument(named: "shot.json")
        var corridas = 0
        // ProgramDirector.steps es el director entero (IOS-37): aquí solo la gramática.
        for caso in documento.cases where caso.fn == "ShotGrammar.steps" {
            corridas += 1
            if let fallo = Golden.mismatch(
                actual: try Self.pasos(caso.inputs),
                expected: caso.expected,
                tol: caso.tol,
                path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridas, 1)
    }

    func testElPlanSeRecortaALaLente() throws {
        let libre = try ShotPlan.at()
        let tope = libre.hfovRad[.normal]!
        let recortado = try ShotPlan.at(hfovMinRad: tope)
        // El ATTACK que no cabe sale como el más cerrado que sí cabe.
        XCTAssertEqual(recortado.hfovRad[.attack], tope)
        XCTAssertLessThan(libre.hfovRad[.attack]!, tope)
        XCTAssertThrowsError(try ShotPlan.at(hfovMinRad: 1, hfovMaxRad: 0.5))
    }

    func testAbrirEsMasRapidoQueCerrar() throws {
        let plan = try ShotPlan.at()
        let dt = 1.0 / 30
        let normal = PlayerEvidence(
            direction: RigDirection(yawRad: 0, pitchRad: -0.1),
            spreadRad: (plan.tightRad + plan.stretchedRad) / 2, players: 14, bimodality: 0, confidence: 0.8
        )
        func ciclos(hasta objetivo: ShotSize, desde inicio: ShotSize, con evidencia: PlayerEvidence) throws -> Int {
            let gramatica = ShotGrammar(plan: plan, shot: inicio)
            // Permanencia cumplida antes de empezar: aquí solo se mide la insistencia.
            let previo = Int((RigConstants.shotDwellMinS / dt).rounded(.up)) + 1
            for _ in 0..<previo {
                XCTAssertEqual(try gramatica.step(normal, dtS: dt).shot, inicio)
            }
            for n in 1...3000 where try gramatica.step(evidencia, dtS: dt).shot == objetivo {
                return n
            }
            return Int.max
        }
        let concentrado = PlayerEvidence(
            direction: RigDirection(yawRad: 0, pitchRad: -0.1),
            spreadRad: plan.tightRad / 2, players: 14, bimodality: 0, confidence: 0.8
        )
        let estirado = PlayerEvidence(
            direction: RigDirection(yawRad: 0, pitchRad: -0.1),
            spreadRad: plan.stretchedRad * 2, players: 14, bimodality: 0, confidence: 0.8
        )
        let cerrar = try ciclos(hasta: .attack, desde: .normal, con: concentrado)
        let abrir = try ciclos(hasta: .wide, desde: .normal, con: estirado)
        XCTAssertLessThan(abrir, cerrar)
    }

    func testSinJugadoresAbreSinEsperarLaPermanencia() throws {
        let gramatica = ShotGrammar(plan: try ShotPlan.at(), shot: .attack)
        var abierto = false
        let dt = 1.0 / 30
        let tope = Int((RigConstants.shotDwellMinS / dt).rounded(.down))
        for _ in 0..<tope where try gramatica.step(nil, dtS: dt).shot == .wide {
            abierto = true
        }
        XCTAssertTrue(abierto, "urgente: no espera SHOT_DWELL_MIN_S")
    }

    private static func pasos(_ inputs: GoldenValue) throws -> GoldenValue {
        let p = try inputs.field("plan")
        guard let crudos = try p.field("hfov_rad").objectValue else {
            throw GoldenError.message("hfov_rad no es un objeto")
        }
        var hfov: [ShotSize: Double] = [:]
        for (nombre, valor) in crudos {
            guard let plano = ShotSize(rawValue: nombre), let v = valor.numberValue else {
                throw GoldenError.message("plano desconocido: \(nombre)")
            }
            hfov[plano] = v
        }
        let gramatica = ShotGrammar(
            plan: try ShotPlan(
                hfovRad: hfov, tightRad: p.number("tight_rad"), stretchedRad: p.number("stretched_rad")
            )
        )
        guard case let .array(pasos)? = try? inputs.field("steps") else {
            throw GoldenError.message("steps no es una lista")
        }
        let dt = try inputs.number("dt_s")
        var planos: [GoldenValue] = []
        var razones: [GoldenValue] = []
        var anchos: [Double] = []
        var cambios: [UInt8] = []
        for paso in pasos {
            if try paso.field("mark_situation").boolValue == true {
                gramatica.markSituation()
            }
            let e = try paso.field("evidence")
            let evidencia: PlayerEvidence? = e == .null ? nil : PlayerEvidence(
                direction: RigDirection(yawRad: try e.number("yaw_rad"), pitchRad: try e.number("pitch_rad")),
                spreadRad: try e.number("spread_rad"),
                players: Int(try e.number("players")),
                bimodality: try e.number("bimodality"),
                confidence: try e.number("confidence")
            )
            let decision = try gramatica.step(evidencia, dtS: dt)
            planos.append(.string(decision.shot.rawValue))
            razones.append(.string(decision.reason))
            anchos.append(decision.hfovRad)
            cambios.append(decision.changed ? 1 : 0)
        }
        return .object([
            "shot": .array(planos),
            "reason": .array(razones),
            "hfov_rad": .tensor(f64: anchos, shape: [anchos.count]),
            "changed": .tensor(u8: cambios, shape: [cambios.count]),
        ])
    }
}
