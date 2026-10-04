// El punto de acción contra los dorados de action.json (IOS-33).

import Foundation
import RigCore
import XCTest

private struct Avistamiento: ActionSighting {
    let direction: RigDirection
    let playerClass: PlayerClass
    let score: Double
}

final class ActionTests: XCTestCase {
    func testLosDoradosDeAction() throws {
        let documento = try Golden.loadDocument(named: "action.json")
        var porFn: [String: Int] = [:]
        for caso in documento.cases {
            let actual: GoldenValue
            switch caso.fn {
            case "yaw_density":
                actual = try Self.densidad(caso.inputs)
            case "action_from_players":
                actual = try Self.accion(caso.inputs)
            default:
                XCTFail("fn sin réplica en action.json: \(caso.fn)")
                continue
            }
            porFn[caso.fn, default: 0] += 1
            if let fallo = Golden.mismatch(
                actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(porFn["yaw_density"] ?? 0, 1)
        // Unimodal, bimodal, pocos jugadores (nil) y plantilla completa con porteros
        // y árbitros apartados.
        XCTAssertGreaterThanOrEqual(porFn["action_from_players"] ?? 0, 4)
    }

    func testSinJugadoresDeCampoNoHayEvidencia() {
        let estimador = ActionEstimator(playerCapacity: 8)
        let sinCampo = [
            Avistamiento(direction: RigDirection(yawRad: 0, pitchRad: 0), playerClass: .referee, score: 0.9),
            Avistamiento(direction: RigDirection(yawRad: 0.1, pitchRad: 0), playerClass: .goalkeeper, score: 0.9),
            Avistamiento(direction: RigDirection(yawRad: 0.2, pitchRad: 0), playerClass: .player, score: 0),
            Avistamiento(direction: RigDirection(yawRad: 0.3, pitchRad: 0), playerClass: .player, score: 0.8),
        ]
        XCTAssertNil(estimador.evidence(from: sinCampo))
        XCTAssertNil(estimador.evidence(from: [Avistamiento]()))
    }

    func testElEstimadorNoArrastraEstadoEntreCiclos() throws {
        // Reutilizar los búferes no puede dejar restos: el mismo ciclo da lo mismo
        // tras uno más grande y con más rejilla.
        let estimador = ActionEstimator(playerCapacity: 4)
        let pequeno = (0..<5).map {
            Avistamiento(
                direction: RigDirection(yawRad: 0.05 * Double($0), pitchRad: -0.1),
                playerClass: .player, score: 0.9
            )
        }
        let grande = (0..<30).map {
            Avistamiento(
                direction: RigDirection(yawRad: -1.2 + 0.08 * Double($0), pitchRad: -0.12),
                playerClass: .player, score: 0.7
            )
        }
        let primera = try XCTUnwrap(estimador.evidence(from: pequeno))
        _ = estimador.evidence(from: grande)
        XCTAssertEqual(estimador.evidence(from: pequeno), primera)
        XCTAssertLessThanOrEqual(primera.confidence, 0.8, "sin convergencia, tope 0.80")
    }

    // MARK: - El runner

    private static func densidad(_ inputs: GoldenValue) throws -> GoldenValue {
        let (grid, density) = ActionEstimator.yawDensity(
            yaws: try tensor(inputs, "yaws"),
            weights: try tensor(inputs, "weights"),
            bandwidthRad: try inputs.number("bandwidth_rad"),
            stepRad: try inputs.number("step_rad")
        )
        return .object([
            "grid": .tensor(f64: grid, shape: [grid.count]),
            "density": .tensor(f64: density, shape: [density.count]),
        ])
    }

    private static func accion(_ inputs: GoldenValue) throws -> GoldenValue {
        guard case let .array(crudas)? = try? inputs.field("detections") else {
            throw GoldenError.message("detections no es una lista")
        }
        let avistamientos = try crudas.map { cruda in
            guard let clase = PlayerClass(rawValue: try cruda.string("cls")) else {
                throw GoldenError.message("clase desconocida")
            }
            return Avistamiento(
                direction: RigDirection(
                    yawRad: try cruda.number("yaw_rad"), pitchRad: try cruda.number("pitch_rad")
                ),
                playerClass: clase,
                score: try cruda.number("score")
            )
        }
        let estimador = ActionEstimator(
            playerCapacity: avistamientos.count,
            bandwidthRad: try inputs.number("bandwidth_rad"),
            minPlayers: Int(try inputs.number("min_players"))
        )
        guard let evidencia = estimador.evidence(from: avistamientos) else {
            return .object(["evidence": .null])
        }
        return .object([
            "evidence": .object([
                "yaw_rad": .number(evidencia.direction.yawRad),
                "pitch_rad": .number(evidencia.direction.pitchRad),
                "spread_rad": .number(evidencia.spreadRad),
                "players": .number(Double(evidencia.players)),
                "bimodality": .number(evidencia.bimodality),
                "confidence": .number(evidencia.confidence),
                "sigma_rad": .number(evidencia.sigmaRad),
            ]),
        ])
    }

    private static func tensor(_ inputs: GoldenValue, _ clave: String) throws -> [Double] {
        guard let tensor = try inputs.field(clave).tensorValue else {
            throw GoldenError.message("\(clave) no es un tensor")
        }
        return try tensor.doubles()
    }
}
