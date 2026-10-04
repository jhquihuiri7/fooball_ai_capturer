// La geometría del soporte contra los dorados de REF-11 (IOS-30).
//
// Un runner por `fn`: cada caso de rig.json se recalcula con la réplica Swift y se
// compara con Golden.mismatch, que nombra el campo exacto que se desvía. La fusión
// (RigModel.fuse) se salta A PROPÓSITO: llega con IOS-32, y el meta-test exige que
// lo saltado sea exactamente eso y nada más.

import Foundation
import RigCore
import XCTest

final class RigModelTests: XCTestCase {
    func testLosDoradosDelRig() throws {
        let documento = try Golden.loadDocument(named: "rig.json")
        var saltados: Set<String> = []
        var corridos = 0
        for caso in documento.cases {
            guard let actual = try Self.replica(fn: caso.fn, inputs: caso.inputs) else {
                saltados.insert(caso.fn)
                continue
            }
            corridos += 1
            if let fallo = Golden.mismatch(
                actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertEqual(saltados, [], "desde IOS-32 el dorado del rig se replica ENTERO")
        XCTAssertGreaterThanOrEqual(corridos, 33, "el dorado del rig trae más casos que esto")
    }

    func testCargaUnSoporteRealDelPod() throws {
        guard let url = Bundle.module.url(
            forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures"
        ) else {
            return XCTFail("falta Fixtures/soporte-pod.json")
        }
        let rig = try RigModel.load(from: url)
        // La calibración nominal del pod: 4K, las cámaras a ±40° y la izquierda
        // montada del revés (roll π). Lo que importa: carga, y la geometría responde.
        XCTAssertEqual(rig.camera(.left).intrinsics.width, 3840)
        XCTAssertEqual(rig.camera(.left).pose.rollRad, .pi, accuracy: 1e-12)
        XCTAssertTrue(rig.inOverlap(RigDirection(yawRad: 0, pitchRad: -0.14)))
        XCTAssertFalse(rig.sees(.left, direction: RigDirection(yawRad: 1.3, pitchRad: 0)))
    }

    func testOtraVersionDeRigJsonSeRechaza() {
        XCTAssertThrowsError(try RigModel.fromDictionary(["version": 2]))
        XCTAssertThrowsError(try RigModel.fromDictionary([:]))
    }

    // MARK: - El runner

    private static func replica(fn: String, inputs: GoldenValue) throws -> GoldenValue? {
        switch fn {
        case "CameraPose.matrix":
            let pose = try pose(from: inputs)
            return .object(["matrix": .tensor(f64: pose.matrix().values, shape: [3, 3])])

        case "CameraPose.from_matrix":
            guard let tensor = try inputs.field("matrix").tensorValue else {
                throw GoldenError.message("matrix no es un tensor")
            }
            let pose = try CameraPose.fromMatrix(Mat3(rows: tensor.doubles()))
            return .object([
                "yaw_rad": .number(pose.yawRad),
                "pitch_rad": .number(pose.pitchRad),
                "roll_rad": .number(pose.rollRad),
            ])

        case "CameraIntrinsics.from_hfov":
            let intr = try CameraIntrinsics.fromHfov(
                width: Int(inputs.number("width")),
                height: Int(inputs.number("height")),
                hfovRad: inputs.number("hfov_rad")
            )
            return fields(of: intr)

        case "CameraIntrinsics.scaled":
            let base = try intrinsics(from: inputs.field("intrinsics"))
            return try fields(of: base.scaled(inputs.number("factor")))

        case "RigModel.direction_of":
            let rig = try rig(from: inputs)
            let direccion = try rig.directionOf(
                side(from: inputs), xPx: inputs.number("x_px"), yPx: inputs.number("y_px")
            )
            return .object([
                "yaw_rad": .number(direccion.yawRad),
                "pitch_rad": .number(direccion.pitchRad),
            ])

        case "RigModel.project":
            let pixel = try rig(from: inputs)
                .project(side(from: inputs), direction: direction(from: inputs.field("direction")))
            guard let pixel else { return .object(["pixel": .null]) }
            return .object(["pixel": .array([.number(pixel.x), .number(pixel.y)])])

        case "RigModel.project_rays":
            guard let tensor = try inputs.field("rays").tensorValue else {
                throw GoldenError.message("rays no es un tensor")
            }
            let planos = try tensor.doubles()
            let rayos = stride(from: 0, to: planos.count, by: 3).map {
                Vec3(planos[$0], planos[$0 + 1], planos[$0 + 2])
            }
            let (xs, ys, dentro) = try rig(from: inputs).projectRays(side(from: inputs), rays: rayos)
            return .object([
                "x_px": .tensor(f64: xs, shape: [xs.count]),
                "y_px": .tensor(f64: ys, shape: [ys.count]),
                "inside": .tensor(u8: dentro.map { $0 ? 1 : 0 }, shape: [dentro.count]),
            ])

        case "RigModel.sees":
            let visto = try rig(from: inputs)
                .sees(side(from: inputs), direction: direction(from: inputs.field("direction")))
            return .object(["sees": .bool(visto)])

        case "RigModel.in_overlap":
            let dentro = try rig(from: inputs)
                .inOverlap(direction(from: inputs.field("direction")))
            return .object(["in_overlap": .bool(dentro)])

        case "angular_distance_rad":
            let angulo = try angularDistanceRad(
                direction(from: inputs.field("a")), direction(from: inputs.field("b"))
            )
            return .object(["angle_rad": .number(angulo)])

        case "RigModel.from_dict":
            guard let crudo = try inputs.field("data").jsonObject() as? [String: Any] else {
                throw GoldenError.message("data no es un objeto")
            }
            let rig = try RigModel.fromDictionary(crudo)
            return .object(["data": GoldenValue.from(json: rig.toDictionary())])

        case "RigModel.fuse":
            guard case let .array(crudas)? = try? inputs.field("observations") else {
                throw GoldenError.message("observations no es una lista")
            }
            let observaciones = try crudas.map { cruda in
                Observation(
                    side: CameraSide(rawValue: try cruda.string("side"))!,
                    xPx: try cruda.number("x_px"),
                    yPx: try cruda.number("y_px"),
                    score: try cruda.number("score"),
                    key: Int(try cruda.number("key"))
                )
            }
            let fundidas = try rig(from: inputs)
                .fuse(observaciones, maxAngleRad: inputs.number("max_angle_rad"))
            return .object([
                "fused": .array(fundidas.map { item in
                    .object([
                        "yaw_rad": .number(item.direction.yawRad),
                        "pitch_rad": .number(item.direction.pitchRad),
                        "score": .number(item.score),
                        "sides": .array(item.sides.map { .string($0.rawValue) }),
                        "keys": .array(item.keys.map { .number(Double($0)) }),
                        "separation_rad": .number(item.separationRad),
                    ])
                }),
            ])

        default:
            throw GoldenError.message("fn sin réplica: \(fn)")
        }
    }

    // MARK: - Lectura de entradas

    private static func pose(from valor: GoldenValue) throws -> CameraPose {
        try CameraPose(
            yawRad: valor.number("yaw_rad"),
            pitchRad: valor.number("pitch_rad"),
            rollRad: valor.number("roll_rad")
        )
    }

    private static func direction(from valor: GoldenValue) throws -> RigDirection {
        try RigDirection(yawRad: valor.number("yaw_rad"), pitchRad: valor.number("pitch_rad"))
    }

    private static func intrinsics(from valor: GoldenValue) throws -> CameraIntrinsics {
        try CameraIntrinsics(
            fx: valor.number("fx"),
            fy: valor.number("fy"),
            cx: valor.number("cx"),
            cy: valor.number("cy"),
            width: Int(valor.number("width")),
            height: Int(valor.number("height"))
        )
    }

    private static func rig(from inputs: GoldenValue) throws -> RigModel {
        guard let crudo = try inputs.field("rig").jsonObject() as? [String: Any] else {
            throw GoldenError.message("rig no es un objeto")
        }
        return try RigModel.fromDictionary(crudo)
    }

    private static func side(from inputs: GoldenValue) throws -> CameraSide {
        guard let lado = CameraSide(rawValue: try inputs.string("side")) else {
            throw GoldenError.message("side desconocido")
        }
        return lado
    }

    private static func fields(of intr: CameraIntrinsics) -> GoldenValue {
        .object([
            "fx": .number(intr.fx),
            "fy": .number(intr.fy),
            "cx": .number(intr.cx),
            "cy": .number(intr.cy),
            "width": .number(Double(intr.width)),
            "height": .number(Double(intr.height)),
        ])
    }
}
