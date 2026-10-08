// El Kalman del balón contra ball.json (IOS-28): el filtro operación a operación, el
// tracker fotograma a fotograma a 30 fps y la fusión de las dos cámaras, como los evalúa
// tools/golden/evaluate_ball_kalman.py. Después, lo que un dorado no nombra solo.

import Foundation
import RigCore
import XCTest

final class BallKalmanTests: XCTestCase {
    func testLosDoradosDelBalon() throws {
        let documento = try Golden.loadDocument(named: "ball.json")
        var porFuncion: [String: Int] = [:]
        for caso in documento.cases {
            let actual = try Self.replica(fn: caso.fn, inputs: caso.inputs)
            porFuncion[caso.fn, default: 0] += 1
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        // REF-28c: 1 caso del filtro, 10 secuencias y 4 fusiones. Si baja, el sync trajo otro.
        XCTAssertEqual(porFuncion, ["BallKalman.ops": 1, "BallTracker.sequence": 10, "fuse_estimates": 4])
    }

    /// La edad caduca cuando pasa ESTRICTAMENTE de 0,5 s. En Double, quince fotogramas de
    /// 1/30 suman 0,49999999999999994 y la pista sigue hasta el 16. En Float suman 0,5
    /// justos: con `>` también caducaría en el 16 (y el dorado no lo ve), pero con `>=`
    /// caducaría en el 15 (y el dorado sí lo ve).
    func testLaEdadSeAcumulaEnDoubleYCaducaEnElFotograma16() throws {
        let dt = 1.0 / 30.0
        var enFloat: Float = 0
        for _ in 0..<15 { enFloat += Float(dt) }
        XCTAssertEqual(enFloat, 0.5)

        var tracker = try BallTracker(width: 3840, height: 2160)
        tracker.update([BallDetection(xPx: 1000, yPx: 900, score: 0.8)])
        for fotograma in 1...15 {
            try tracker.predict(dtS: dt)
            XCTAssertNotNil(tracker.estimate(), "caducó en el fotograma \(fotograma)")
        }
        XCTAssertEqual(tracker.estimate()?.ageS, 0.49999999999999994)
        try tracker.predict(dtS: dt)
        XCTAssertNil(tracker.estimate())
        XCTAssertEqual(tracker.state, .lost)
    }

    /// Una detección suelta abre una candidata y no saca de LOST (ni baja la búsqueda
    /// global); otra en su puerta la confirma.
    func testLaCandidataNecesitaUnaSegundaDeteccion() throws {
        var tracker = try BallTracker(width: 3840, height: 2160)
        XCTAssertEqual(tracker.update([BallDetection(xPx: 1000, yPx: 900, score: 0.6)]), 0)
        XCTAssertEqual(tracker.state, .lost)
        XCTAssertEqual(tracker.globalSearchHz, DetectionSpec.ballGlobalLostHz)
        XCTAssertEqual(tracker.estimate()?.confidence, 0.6)

        try tracker.predict(dtS: 2.0 / 30.0)
        let lejos = BallDetection(xPx: 3000, yPx: 300, score: 0.99)
        let cerca = BallDetection(xPx: 1010, yPx: 902, score: 0.7)
        XCTAssertEqual(tracker.update([lejos, cerca]), 1)
        XCTAssertEqual(tracker.state, .tracking)
        XCTAssertEqual(tracker.globalSearchHz, DetectionSpec.ballGlobalHz)
    }

    /// Un ciclo sin nada en la puerta deja la pista en COASTING sin tocar el filtro; un
    /// fotograma sin detector (sin `update`) no cambia el estado.
    func testCoastingSinTocarElFiltro() throws {
        var tracker = try BallTracker(width: 3840, height: 2160)
        tracker.update([BallDetection(xPx: 1000, yPx: 900, score: 0.8)])
        try tracker.predict(dtS: 2.0 / 30.0)
        tracker.update([BallDetection(xPx: 1060, yPx: 900, score: 0.8)])
        try tracker.predict(dtS: 1.0 / 30.0)
        XCTAssertEqual(tracker.state, .tracking)
        let antes = try XCTUnwrap(tracker.estimate())
        XCTAssertNil(tracker.update([BallDetection(xPx: 3000, yPx: 200, score: 0.99)]))
        XCTAssertEqual(tracker.state, .coasting)
        XCTAssertEqual(tracker.estimate(), BallEstimate(
            state: .coasting, xPx: antes.xPx, yPx: antes.yPx, vxPxS: antes.vxPxS, vyPxS: antes.vyPxS,
            varXPx2: antes.varXPx2, varYPx2: antes.varYPx2, confidence: antes.confidence, ageS: antes.ageS
        ))
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
        XCTAssertThrowsError(try BallTracker(width: 0, height: 2160))
        XCTAssertThrowsError(try BallTracker(width: 3840, height: 2160, roiSides: []))
        var tracker = try BallTracker(width: 3840, height: 2160)
        XCTAssertThrowsError(try tracker.predict(dtS: -0.01))
        // Sin detecciones válidas (score 0) no nace nada.
        XCTAssertNil(tracker.update([BallDetection(xPx: 10, yPx: 10, score: 0)]))
        XCTAssertNil(tracker.estimate())
    }

    // MARK: - La réplica del evaluador

    static func replica(fn: String, inputs: GoldenValue) throws -> GoldenValue {
        switch fn {
        case "BallKalman.ops": return try kalmanOps(inputs)
        case "BallTracker.sequence": return try sequence(inputs)
        case "fuse_estimates": return try fuse(inputs)
        default: throw GoldenError.message("fn sin réplica: \(fn)")
        }
    }

    /// El estado de los dos ejes tras cada operación y el d² de cada medida antes de tomarla.
    private static func kalmanOps(_ inputs: GoldenValue) throws -> GoldenValue {
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

    /// Fotograma a fotograma: predict, rois y, si hubo ciclo, update.
    private static func sequence(_ inputs: GoldenValue) throws -> GoldenValue {
        let maxRois = Int(try inputs.number("max_rois"))
        var tracker = try BallTracker(
            width: Int(inputs.number("width")), height: Int(inputs.number("height")),
            roiSides: numbers(inputs.field("roi_sides")).map { Int($0) }, maxRois: maxRois
        )
        let dt = try inputs.number("dt_s")
        let grupos = try list(inputs.field("groups")).map { g -> (x: Double, y: Double) in
            let n = try numbers(g)
            return (n[0], n[1])
        }
        let detecciones = try tensor(inputs.field("detections"))
        let ciclos = try tensor(inputs.field("cycle")).doubles()
        let (fotogramas, ancho) = (detecciones.shape[0], detecciones.shape[1])
        let crudas = try detecciones.doubles()

        var estados: [GoldenValue] = []
        var fuentes: [GoldenValue] = []
        var estimacion = [Double](repeating: 0, count: fotogramas * 8)
        var conEstimacion = [UInt8](repeating: 0, count: fotogramas)
        var aceptada = [Int32](repeating: -1, count: fotogramas)
        var rois = [Int32](repeating: 0, count: fotogramas * maxRois * 3)
        var cuantas = [Int32](repeating: 0, count: fotogramas)
        var hz = [Int32](repeating: 0, count: fotogramas)
        for k in 0..<fotogramas {
            try tracker.predict(dtS: dt)
            let delCiclo = tracker.rois(groups: grupos)
            for (j, roi) in delCiclo.enumerated() {
                let base = (k * maxRois + j) * 3
                (rois[base], rois[base + 1], rois[base + 2]) = (Int32(roi.x), Int32(roi.y), Int32(roi.side))
            }
            cuantas[k] = Int32(delCiclo.count)
            fuentes.append(.array(delCiclo.map { .string($0.source.rawValue) }))
            if ciclos[k] != 0 {
                let lista = (0..<ancho).compactMap { j -> BallDetection? in
                    let base = (k * ancho + j) * 3
                    guard !crudas[base].isNaN else { return nil }
                    return BallDetection(xPx: crudas[base], yPx: crudas[base + 1], score: crudas[base + 2])
                }
                if let tomada = tracker.update(lista) { aceptada[k] = Int32(tomada) }
            }
            if let e = tracker.estimate() {
                conEstimacion[k] = 1
                let fila = [e.xPx, e.yPx, e.vxPxS, e.vyPxS, e.varXPx2, e.varYPx2, e.confidence, e.ageS]
                estimacion.replaceSubrange((k * 8)..<(k * 8 + 8), with: fila)
            }
            estados.append(.string(tracker.state.rawValue))
            hz[k] = Int32(tracker.globalSearchHz)
        }
        return .object([
            "state": .array(estados),
            "estimate": .tensor(f64: estimacion, shape: [fotogramas, 8]),
            "has_estimate": .tensor(u8: conEstimacion, shape: [fotogramas]),
            "accepted": .tensor(i32: aceptada, shape: [fotogramas]),
            "rois": .tensor(i32: rois, shape: [fotogramas, maxRois, 3]),
            "roi_count": .tensor(i32: cuantas, shape: [fotogramas]),
            "roi_sources": .array(fuentes),
            "global_hz": .tensor(i32: hz, shape: [fotogramas]),
        ])
    }

    private static func fuse(_ inputs: GoldenValue) throws -> GoldenValue {
        guard let crudo = try inputs.field("rig").jsonObject() as? [String: Any] else {
            throw GoldenError.message("rig no es un objeto")
        }
        let rig = try RigModel.fromDictionary(crudo)
        var estimaciones: [CameraSide: BallEstimate] = [:]
        for lado in CameraSide.allCases {
            let e = try inputs.field("estimates").field(lado.rawValue)
            if e == .null { continue }
            guard let estado = BallKalmanState(rawValue: try e.string("state")) else {
                throw GoldenError.message("estado desconocido")
            }
            estimaciones[lado] = try BallEstimate(
                state: estado, xPx: e.number("x_px"), yPx: e.number("y_px"),
                vxPxS: e.number("vx_px_s"), vyPxS: e.number("vy_px_s"),
                varXPx2: e.number("var_x_px2"), varYPx2: e.number("var_y_px2"),
                confidence: e.number("confidence"), ageS: e.number("age_s")
            )
        }
        guard let f = rig.fuseBall(estimaciones, maxAngleRad: try inputs.number("max_angle_rad")) else {
            return .object(["fused": .null])
        }
        return .object([
            "fused": .object([
                "yaw_rad": .number(f.direction.yawRad),
                "pitch_rad": .number(f.direction.pitchRad),
                "score": .number(f.score),
                "sides": .array(f.sides.map { .string($0.rawValue) }),
                "keys": .array(f.keys.map { .number(Double($0)) }),
                "separation_rad": .number(f.separationRad),
            ]),
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
