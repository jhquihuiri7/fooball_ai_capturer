// La cámara virtual contra los dorados de REF-11 (IOS-31).

import Foundation
import RigCore
import XCTest

final class RectilinearViewTests: XCTestCase {
    func testLosDoradosDeReprojection() throws {
        let documento = try Golden.loadDocument(named: "reprojection.json")
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
        // El render de píxeles es IOS-40 (Metal) y el contorno sobre el lienzo es
        // del panel: lo demás se replica entero.
        XCTAssertEqual(saltados, ["ViewRenderer.render", "view_outline"])
        XCTAssertGreaterThanOrEqual(corridos, 14)
    }

    func testLasValidacionesHablanClaro() {
        XCTAssertThrowsError(
            try RectilinearView(yawRad: 0, pitchRad: 0, hfovRad: 0, width: 16, height: 9)
        )
        XCTAssertThrowsError(
            try RectilinearView(yawRad: 0, pitchRad: .pi, hfovRad: 1, width: 16, height: 9)
        )
        XCTAssertThrowsError(
            try RectilinearView(yawRad: 0, pitchRad: 0, hfovRad: 1, width: 0, height: 9)
        )
        let vista = try? RectilinearView(yawRad: 0, pitchRad: 0, hfovRad: 1, width: 16, height: 9)
        XCTAssertThrowsError(
            try vista?.contains(RigDirection(yawRad: 0, pitchRad: 0), margin: 0.5)
        )
    }

    // MARK: - El runner

    static func replica(fn: String, inputs: GoldenValue) throws -> GoldenValue? {
        switch fn {
        case "RectilinearView.geometry":
            let vista = try view(from: inputs)
            return .object([
                "focal_px": .number(vista.focalPx),
                "vfov_rad": .number(vista.vfovRad),
            ])

        case "RectilinearView.with_hfov":
            return try fields(of: view(from: inputs).withHfov(inputs.number("hfov_rad")))

        case "RectilinearView.looking_at":
            let destino = try RigDirection(
                yawRad: inputs.field("direction").number("yaw_rad"),
                pitchRad: inputs.field("direction").number("pitch_rad")
            )
            return try fields(of: view(from: inputs).lookingAt(destino))

        case "RectilinearView.direction_at":
            let direccion = try view(from: inputs)
                .directionAt(xPx: inputs.number("x_px"), yPx: inputs.number("y_px"))
            return .object([
                "yaw_rad": .number(direccion.yawRad),
                "pitch_rad": .number(direccion.pitchRad),
            ])

        case "RectilinearView.contains":
            let direccion = try RigDirection(
                yawRad: inputs.field("direction").number("yaw_rad"),
                pitchRad: inputs.field("direction").number("pitch_rad")
            )
            let dentro = try view(from: inputs)
                .contains(direccion, margin: inputs.number("margin"))
            return .object(["contains": .bool(dentro)])

        case "view_homography":
            let h = try viewHomography(
                rig: rig(from: inputs), view: view(from: inputs), side: side(from: inputs)
            )
            return .object(["h": .tensor(f64: h.values, shape: [3, 3])])

        case "sides_for":
            let lados = try sidesFor(rig: rig(from: inputs), view: view(from: inputs))
            return .object(["sides": .array(lados.map { .string($0.rawValue) })])

        case "ViewRenderer.render", "view_outline":
            return nil

        default:
            throw GoldenError.message("fn sin réplica: \(fn)")
        }
    }

    static func view(from inputs: GoldenValue) throws -> RectilinearView {
        let crudo = try inputs.field("view")
        return try RectilinearView(
            yawRad: crudo.number("yaw_rad"),
            pitchRad: crudo.number("pitch_rad"),
            hfovRad: crudo.number("hfov_rad"),
            width: Int(crudo.number("width")),
            height: Int(crudo.number("height"))
        )
    }

    static func rig(from inputs: GoldenValue) throws -> RigModel {
        guard let crudo = try inputs.field("rig").jsonObject() as? [String: Any] else {
            throw GoldenError.message("rig no es un objeto")
        }
        return try RigModel.fromDictionary(crudo)
    }

    static func side(from inputs: GoldenValue) throws -> CameraSide {
        guard let lado = CameraSide(rawValue: try inputs.string("side")) else {
            throw GoldenError.message("side desconocido")
        }
        return lado
    }

    private static func fields(of vista: RectilinearView) -> GoldenValue {
        .object([
            "yaw_rad": .number(vista.yawRad),
            "pitch_rad": .number(vista.pitchRad),
            "hfov_rad": .number(vista.hfovRad),
            "width": .number(Double(vista.width)),
            "height": .number(Double(vista.height)),
        ])
    }
}
