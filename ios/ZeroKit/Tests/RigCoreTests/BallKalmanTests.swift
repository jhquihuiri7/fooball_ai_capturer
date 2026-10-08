// El filtro del balón contra ball.json (IOS-28a): `BallKalman` operación a operación,
// como lo evalúa tools/golden/evaluate_ball_kalman.py. Las secuencias del tracker y la
// fusión llegan con IOS-28b; el meta-test exige que lo saltado sea exactamente eso.

import Foundation
import RigCore
import XCTest

final class BallKalmanTests: XCTestCase {
    func testLosDoradosDelFiltro() throws {
        let documento = try Golden.loadDocument(named: "ball.json")
        var saltados: Set<String> = []
        var corridos = 0
        for caso in documento.cases {
            guard caso.fn == "BallKalman.ops" else {
                saltados.insert(caso.fn)
                continue
            }
            corridos += 1
            let actual = try Self.kalmanOps(caso.inputs)
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertEqual(saltados, ["BallTracker.sequence", "fuse_estimates"], "llegan con IOS-28b")
        XCTAssertEqual(corridos, 1)
    }

    /// Al nacer, cada eje tiene la varianza de la medida (2² px²), así que S = 8 por eje y
    /// d² = (dx² + dy²)/8: la puerta de 9,21 deja pasar ~8,6 px y no 9.
    func testLaPuertaAlNacer() throws {
        let filtro = try BallKalman(xPx: 1000, yPx: 900)
        XCTAssertEqual(filtro.positionSigmaPx, 8.0.squareRoot())
        XCTAssertEqual(filtro.mahalanobis2(xPx: 1008, yPx: 900), 8)
        XCTAssertLessThan(filtro.mahalanobis2(xPx: 1006, yPx: 906), DetectionSpec.ballGateChi2)
        XCTAssertGreaterThan(filtro.mahalanobis2(xPx: 1009, yPx: 900), DetectionSpec.ballGateChi2)
    }

    func testRechazaLoQueLaReferenciaRechaza() throws {
        XCTAssertThrowsError(try BallKalman(xPx: 0, yPx: 0, measStdPx: 0))
        XCTAssertThrowsError(try BallKalman(xPx: 0, yPx: 0, accelStdPxS2: -1))
        var filtro = try BallKalman(xPx: 0, yPx: 0)
        XCTAssertThrowsError(try filtro.predict(dtS: -0.01))
    }

    // MARK: - La réplica del evaluador

    /// El estado de los dos ejes tras cada operación y el d² de cada medida antes de tomarla.
    static func kalmanOps(_ inputs: GoldenValue) throws -> GoldenValue {
        let inicio = try numbers(inputs.field("start"))
        var filtro = try BallKalman(xPx: inicio[0], yPx: inicio[1])
        var filas: [Double] = []
        var d2: [Double] = []
        let ops = try list(inputs.field("ops"))
        for op in ops {
            if try op.string("op") == "predict" {
                try filtro.predict(dtS: op.number("dt_s"))
                d2.append(0)
            } else {
                let (x, y) = (try op.number("x_px"), try op.number("y_px"))
                d2.append(filtro.mahalanobis2(xPx: x, yPx: y))
                filtro.update(xPx: x, yPx: y)
            }
            for eje in [filtro.x, filtro.y] {
                filas += [eje.positionPx, eje.velocityPxS, eje.varPosPx2, eje.covPosVelPx2S, eje.varVelPx2S2]
            }
        }
        return .object([
            "state": .tensor(f64: filas, shape: [ops.count, 10]),
            "mahalanobis2": .tensor(f64: d2, shape: [ops.count]),
        ])
    }

    // MARK: - Lectura de entradas

    static func list(_ valor: GoldenValue) throws -> [GoldenValue] {
        guard case let .array(valores) = valor else { throw GoldenError.message("se esperaba una lista") }
        return valores
    }

    static func numbers(_ valor: GoldenValue) throws -> [Double] {
        try list(valor).map { v in
            guard let n = v.numberValue else { throw GoldenError.message("se esperaba un número") }
            return n
        }
    }

    static func tensor(_ valor: GoldenValue) throws -> GoldenTensor {
        guard let t = valor.tensorValue else { throw GoldenError.message("se esperaba un tensor") }
        return t
    }
}
