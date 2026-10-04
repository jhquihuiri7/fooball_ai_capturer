// Los tres ejes montados contra director.json (IOS-34): cobertura del lienzo, límites,
// tope cerrado de la lente y 300 pasos de la cámara virtual con objetivos ausentes.

import Foundation
import RigCore
import XCTest

final class VirtualCameraEngineTests: XCTestCase {
    func testLosDoradosDeLaCamaraVirtual() throws {
        let documento = try Golden.loadDocument(named: "director.json")
        var porFn: [String: Int] = [:]
        for caso in documento.cases where caso.fn != "integrate_axis_sequence" {
            let actual: GoldenValue
            switch caso.fn {
            case "CylindricalCanvas.fit": actual = try Self.fit(caso.inputs)
            case "CameraLimits.from_canvas": actual = try Self.fromCanvas(caso.inputs)
            case "tightest_servable_hfov_rad":
                actual = .object([
                    "hfov_rad": .number(
                        tightestServableHfovRad(
                            try Self.rig(caso.inputs),
                            programWidth: Int(try caso.inputs.number("program_width"))
                        )
                    ),
                ])
            case "VirtualCameraEngine.steps": actual = try Self.pasos(caso.inputs)
            default:
                XCTFail("fn sin réplica en director.json: \(caso.fn)")
                continue
            }
            porFn[caso.fn, default: 0] += 1
            if let fallo = Golden.mismatch(
                actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertEqual(
            Set(porFn.keys),
            [
                "CylindricalCanvas.fit", "CameraLimits.from_canvas",
                "tightest_servable_hfov_rad", "VirtualCameraEngine.steps",
            ]
        )
    }

    func testUnaSolaLenteCubreMenos() throws {
        let rig = try RigModel.load(
            from: Bundle.module.url(forResource: "soporte-pod", withExtension: "json", subdirectory: "Fixtures")!
        )
        let ambas = try CylindricalCanvas.fit(rig)
        let derecha = try CylindricalCanvas.fit(rig, sides: [.right])
        // El modo degradado no puede apuntar a lo que solo veía la izquierda.
        XCTAssertGreaterThan(derecha.yawMinRad, ambas.yawMinRad + 0.5)
        XCTAssertEqual(derecha.yawMaxRad, ambas.yawMaxRad, accuracy: 1e-9)
    }

    func testSinPlanoQueValgaSeRechaza() {
        XCTAssertThrowsError(
            try CameraLimits(yawRad: (-1, 1), pitchRad: (-0.5, 0.2), hfovRad: (1.2, 1.0))
        ) { error in
            XCTAssertTrue("\(error)".contains("ningún plano"))
        }
    }

    func testElRangoColapsaAlCentroSiNoCabe() throws {
        let limites = try CameraLimits(yawRad: (-0.2, 0.4), pitchRad: (-0.5, 0.1), hfovRad: (0.5, 1.0))
        let rango = limites.yawRange(1.0)
        XCTAssertEqual(rango.low, 0.1, accuracy: 1e-15)
        XCTAssertEqual(rango.high, 0.1, accuracy: 1e-15)
    }

    // MARK: - El runner

    private static func rig(_ inputs: GoldenValue) throws -> RigModel {
        guard let crudo = try inputs.field("rig").jsonObject() as? [String: Any] else {
            throw GoldenError.message("rig no es un objeto")
        }
        return try RigModel.fromDictionary(crudo)
    }

    private static func par(_ valor: GoldenValue) throws -> (Double, Double) {
        guard case let .array(lista) = valor, lista.count == 2,
              let a = lista[0].numberValue, let b = lista[1].numberValue
        else { throw GoldenError.message("se esperaba [a, b]") }
        return (a, b)
    }

    private static func fit(_ inputs: GoldenValue) throws -> GoldenValue {
        let focal = try inputs.field("focal_px").numberValue
        let crudoLimites = try inputs.field("pitch_limits_rad")
        let limites: (low: Double, high: Double)? =
            crudoLimites == .null ? nil : try par(crudoLimites)
        let lienzo = try CylindricalCanvas.fit(
            rig(inputs), focalPx: focal, pitchLimitsRad: limites
        )
        return .object([
            "focal_px": .number(lienzo.focalPx),
            "yaw_min_rad": .number(lienzo.yawMinRad),
            "yaw_max_rad": .number(lienzo.yawMaxRad),
            "pitch_min_rad": .number(lienzo.pitchMinRad),
            "pitch_max_rad": .number(lienzo.pitchMaxRad),
            "width": .number(Double(lienzo.width)),
            "height": .number(Double(lienzo.height)),
        ])
    }

    private static func fromCanvas(_ inputs: GoldenValue) throws -> GoldenValue {
        let c = try inputs.field("canvas")
        let lienzo = try CylindricalCanvas(
            focalPx: c.number("focal_px"),
            yawMinRad: c.number("yaw_min_rad"),
            yawMaxRad: c.number("yaw_max_rad"),
            pitchMinRad: c.number("pitch_min_rad"),
            pitchMaxRad: c.number("pitch_max_rad")
        )
        let limites = try CameraLimits.fromCanvas(
            lienzo,
            hfovMinRad: inputs.number("hfov_min_rad"),
            hfovMaxRad: inputs.number("hfov_max_rad"),
            aspect: inputs.number("aspect")
        )
        return .object([
            "yaw_rad": .array([.number(limites.yawLow), .number(limites.yawHigh)]),
            "pitch_rad": .array([.number(limites.pitchLow), .number(limites.pitchHigh)]),
            "hfov_rad": .array([.number(limites.hfovLow), .number(limites.hfovHigh)]),
        ])
    }

    private static func pasos(_ inputs: GoldenValue) throws -> GoldenValue {
        let v = try inputs.field("view")
        let l = try inputs.field("limits")
        let motor = VirtualCameraEngine(
            view: try RectilinearView(
                yawRad: v.number("yaw_rad"),
                pitchRad: v.number("pitch_rad"),
                hfovRad: v.number("hfov_rad"),
                width: Int(v.number("width")),
                height: Int(v.number("height"))
            ),
            limits: try CameraLimits(
                yawRad: par(l.field("yaw_rad")),
                pitchRad: par(l.field("pitch_rad")),
                hfovRad: par(l.field("hfov_rad"))
            )
        )
        func serie(_ clave: String) throws -> [Double] {
            guard let t = try inputs.field(clave).tensorValue else {
                throw GoldenError.message("\(clave) no es un tensor")
            }
            return try t.doubles()
        }
        let objetivoYaw = try serie("target_yaw_rad")
        let objetivoPitch = try serie("target_pitch_rad")
        let objetivoHfov = try serie("target_hfov_rad")
        let urgencia = try serie("urgency")
        let dt = try inputs.number("dt_s")

        var yaw: [Double] = []
        var pitch: [Double] = []
        var hfov: [Double] = []
        var quieta: [UInt8] = []
        for i in objetivoYaw.indices {
            // NaN en el dorado es el None de la referencia: «no tengo nada que decir».
            let objetivo = objetivoYaw[i].isNaN
                ? nil : RigDirection(yawRad: objetivoYaw[i], pitchRad: objetivoPitch[i])
            let plano = objetivoHfov[i].isNaN ? nil : objetivoHfov[i]
            let vista = try motor.step(target: objetivo, hfovRad: plano, dtS: dt, urgency: urgencia[i])
            yaw.append(vista.yawRad)
            pitch.append(vista.pitchRad)
            hfov.append(vista.hfovRad)
            quieta.append(motor.settled ? 1 : 0)
        }
        let n = yaw.count
        return .object([
            "yaw_rad": .tensor(f64: yaw, shape: [n]),
            "pitch_rad": .tensor(f64: pitch, shape: [n]),
            "hfov_rad": .tensor(f64: hfov, shape: [n]),
            "settled": .tensor(u8: quieta, shape: [n]),
        ])
    }
}
