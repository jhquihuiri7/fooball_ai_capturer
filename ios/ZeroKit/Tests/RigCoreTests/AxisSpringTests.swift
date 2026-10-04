// El muelle de un eje contra las tres secuencias doradas de 300 pasos (IOS-34):
// yaw con zona muerta y escalón, pitch contra el muro y zoom a saltos con urgencia.

import Foundation
import RigCore
import XCTest

final class AxisSpringTests: XCTestCase {
    func testLasSecuenciasDoradas() throws {
        let documento = try Golden.loadDocument(named: "director.json")
        var corridas = 0
        for caso in documento.cases where caso.fn == "integrate_axis_sequence" {
            corridas += 1
            let actual = try Self.secuencia(caso.inputs)
            if let fallo = Golden.mismatch(
                actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridas, 3, "paneo, muro y zoom")
    }

    func testLosParametrosPorEjeSonValidos() {
        // Los `try!` de AxisParams.yaw/pitch/hfov: si una constante generada los
        // rompiera, esto revienta aquí y no en el directo.
        XCTAssertLessThan(AxisParams.yaw.deadInFrac, AxisParams.yaw.deadOutFrac)
        XCTAssertLessThan(AxisParams.pitch.deadInFrac, AxisParams.pitch.deadOutFrac)
        XCTAssertEqual(AxisParams.hfov.deadInFrac, AxisParams.hfov.deadOutFrac)
    }

    func testRechazaParametrosSinHisteresis() {
        XCTAssertThrowsError(
            try AxisParams(
                fnBaseHz: 1, fnUrgentGainHz: 0, zeta: 1, vMaxRadS: 1, aMaxRadS2: 1,
                targetSlewRadS: 1, deadOutFrac: 0.01, deadInFrac: 0.02, wallMarginFrac: 0
            )
        )
    }

    func testRechazaEntradasImposibles() {
        let estado = AxisState.at(0)
        XCTAssertThrowsError(
            try integrateAxis(estado, targetRad: 1, params: .yaw, dtS: 0, scaleRad: 1, limits: (-1, 1))
        )
        XCTAssertThrowsError(
            try integrateAxis(estado, targetRad: 1, params: .yaw, dtS: 0.1, scaleRad: 0, limits: (-1, 1))
        )
        XCTAssertThrowsError(
            try integrateAxis(estado, targetRad: 1, params: .yaw, dtS: 0.1, scaleRad: 1, limits: (1, -1))
        )
    }

    func testNoSePasaDelObjetivo() throws {
        // ζ = 1: un escalón se persigue sin rebasarlo nunca.
        var estado = AxisState.at(0)
        for _ in 0..<600 {
            estado = try integrateAxis(
                estado, targetRad: 0.5, params: .yaw, dtS: 1.0 / 30, scaleRad: 1, limits: (-1.5, 1.5)
            )
            XCTAssertLessThanOrEqual(estado.positionRad, 0.5)
        }
        XCTAssertGreaterThan(estado.positionRad, 0.4)
    }

    private static func secuencia(_ inputs: GoldenValue) throws -> GoldenValue {
        let p = try inputs.field("params")
        let params = try AxisParams(
            fnBaseHz: p.number("fn_base_hz"),
            fnUrgentGainHz: p.number("fn_urgent_gain_hz"),
            zeta: p.number("zeta"),
            vMaxRadS: p.number("v_max_rad_s"),
            aMaxRadS2: p.number("a_max_rad_s2"),
            targetSlewRadS: p.number("target_slew_rad_s"),
            deadOutFrac: p.number("dead_out_frac"),
            deadInFrac: p.number("dead_in_frac"),
            wallMarginFrac: p.number("wall_margin_frac")
        )
        let s = try inputs.field("state")
        var estado = AxisState(
            positionRad: try s.number("position_rad"),
            velocityRadS: try s.number("velocity_rad_s"),
            targetRad: try s.number("target_rad"),
            engaged: try s.field("engaged").boolValue ?? false
        )
        guard case let .array(limites)? = try? inputs.field("limits"),
              let bajo = limites.first?.numberValue, let alto = limites.last?.numberValue,
              let objetivos = try inputs.field("targets").tensorValue
        else {
            throw GoldenError.message("limits o targets mal formados")
        }
        var posicion: [Double] = []
        var velocidad: [Double] = []
        var perseguido: [Double] = []
        var enganchado: [UInt8] = []
        for objetivo in try objetivos.doubles() {
            estado = try integrateAxis(
                estado,
                targetRad: objetivo,
                params: params,
                dtS: try inputs.number("dt_s"),
                scaleRad: try inputs.number("scale_rad"),
                limits: (bajo, alto),
                urgency: try inputs.number("urgency")
            )
            posicion.append(estado.positionRad)
            velocidad.append(estado.velocityRadS)
            perseguido.append(estado.targetRad)
            enganchado.append(estado.engaged ? 1 : 0)
        }
        let n = posicion.count
        return .object([
            "position_rad": .tensor(f64: posicion, shape: [n]),
            "velocity_rad_s": .tensor(f64: velocidad, shape: [n]),
            "target_rad": .tensor(f64: perseguido, shape: [n]),
            "engaged": .tensor(u8: enganchado, shape: [n]),
        ])
    }
}
