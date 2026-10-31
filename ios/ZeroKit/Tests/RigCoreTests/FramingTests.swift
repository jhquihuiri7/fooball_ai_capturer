// El encuadre a mano de «Una cámara» contra el dorado framing.json de REF-68 (IOS-115,
// ADR 0033), y el paso suave del controlador con un reloj falso.

import Foundation
import RigCore
import XCTest

final class FramingTests: XCTestCase {
    func testLosDoradosDeFraming() throws {
        let documento = try Golden.loadDocument(named: "framing.json")
        XCTAssertGreaterThanOrEqual(documento.cases.count, 30)
        for caso in documento.cases {
            let actual = try Self.replica(fn: caso.fn, inputs: caso.inputs)
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
    }

    func testElPasoSuaveSigueAlRelojYElCorteLlegaDeGolpe() throws {
        let espacio = try Self.espacio()
        var ahora = 0.0
        let c = FramingController(space: espacio, zoom: 1, nowMs: { ahora })
        XCTAssertEqual(c.framing(), espacio.start(zoom: 1))
        XCTAssertFalse(c.status().moving)

        let destino = try espacio.frameRect(x0: 0.7, y0: 0.6, x1: 0.9, y1: 0.8)
        c.go(to: destino, cut: false)
        XCTAssertTrue(c.status().moving)
        XCTAssertEqual(c.status().target, destino, "el mando ve a dónde va, no por dónde va")
        ahora = RigConstants.cameraMoveMs / 2
        XCTAssertNotEqual(c.framing(), destino)
        ahora = RigConstants.cameraMoveMs
        XCTAssertEqual(c.framing(), destino)
        XCTAssertFalse(c.status().moving)

        c.go(to: espacio.full(), cut: true)
        XCTAssertEqual(c.framing(), espacio.full())
        XCTAssertFalse(c.status().moving)
        XCTAssertEqual(c.status().outline.count, 8)
    }

    func testUnaOrdenAMedioCaminoSaleDeDondeVa() throws {
        let espacio = try Self.espacio()
        var ahora = 0.0
        let c = FramingController(space: espacio, zoom: 0.5, nowMs: { ahora })
        let lejos = try espacio.frameRect(x0: 0.6, y0: 0.4, x1: 0.9, y1: 0.7)
        c.go(to: lejos, cut: false)
        ahora = RigConstants.cameraMoveMs / 2
        let aMedias = c.framing()
        c.go(to: espacio.full(), cut: false)
        let justoDespues = c.framing()
        XCTAssertEqual(justoDespues.centerU, aMedias.centerU, accuracy: 1e-12, "sin salto")
        XCTAssertEqual(justoDespues.hfovRad, aMedias.hfovRad, accuracy: 1e-12)
    }

    func testLasOrdenesMalasHablanClaro() throws {
        let espacio = try Self.espacio()
        XCTAssertThrowsError(try espacio.frameRect(x0: 0.5, y0: 0.5, x1: 0.505, y1: 0.505))
        XCTAssertThrowsError(try espacio.frameRect(x0: .nan, y0: 0, x1: 1, y1: 1))
        XCTAssertThrowsError(try espacio.zoomBy(espacio.full(), factor: 0))
        XCTAssertThrowsError(try espacio.panBy(espacio.full(), dx: 1.5, dy: 0))
        XCTAssertEqual(try espacio.zoomBy(espacio.full(), factor: 0.8), espacio.full(), "más lejos no hay")
    }

    // MARK: - El runner

    /// El espacio del primer caso del dorado: la cámara derecha del soporte nominal a 1080p.
    static func espacio() throws -> FramingSpace {
        try space(from: Golden.loadDocument(named: "framing.json").cases[0].inputs)
    }

    static func space(from inputs: GoldenValue) throws -> FramingSpace {
        let rig = try RectilinearViewTests.rig(from: inputs)
        let lado = try RectilinearViewTests.side(from: inputs)
        return try FramingSpace(
            camera: rig.camera(lado), width: Int(inputs.number("width")), height: Int(inputs.number("height"))
        )
    }

    static func framing(_ crudo: GoldenValue) throws -> Framing {
        try Framing(centerU: crudo.number("center_u"), centerV: crudo.number("center_v"), hfovRad: crudo.number("hfov_rad"))
    }

    static func numbers(_ crudo: GoldenValue) throws -> [Double] {
        guard case let .array(valores) = crudo else { throw GoldenError.message("se esperaba una lista") }
        return try valores.map { valor -> Double in
            guard let n = valor.numberValue else { throw GoldenError.message("la lista lleva algo que no es un número") }
            return n
        }
    }

    static func fields(_ espacio: FramingSpace, _ f: Framing) throws -> GoldenValue {
        let vista = try espacio.view(f)
        return .object([
            "center_u": .number(f.centerU),
            "center_v": .number(f.centerV),
            "hfov_rad": .number(f.hfovRad),
            "yaw_rad": .number(vista.yawRad),
            "pitch_rad": .number(vista.pitchRad),
            "zoom": .number(espacio.zoom(f)),
            "soft": .bool(espacio.soft(f)),
            "outline": .array(espacio.outline(f).map { GoldenValue.array([.number($0.u), .number($0.v)]) }),
        ])
    }

    static func replica(fn: String, inputs: GoldenValue) throws -> GoldenValue {
        switch fn {
        case "full_lens_hfov_rad":
            let rig = try RectilinearViewTests.rig(from: inputs)
            let lado = try RectilinearViewTests.side(from: inputs)
            let hfov = try FullLensView.hfovRad(
                of: rig.camera(lado), width: Int(inputs.number("width")), height: Int(inputs.number("height"))
            )
            return .object(["hfov_rad": .number(hfov)])
        case "zoom_hfov_rad":
            return try .object(["hfov_rad": .number(FullLensView.hfovRad(zoom: inputs.number("zoom")))])
        case "FramingSpace.full":
            let e = try space(from: inputs)
            return try fields(e, e.full())
        case "FramingSpace.start":
            let e = try space(from: inputs)
            return try fields(e, e.start(zoom: inputs.number("zoom")))
        case "FramingSpace.frame_rect":
            let e = try space(from: inputs)
            let r = try numbers(inputs.field("rect"))
            return try fields(e, e.frameRect(x0: r[0], y0: r[1], x1: r[2], y1: r[3]))
        case "FramingSpace.zoom_by":
            let e = try space(from: inputs)
            return try fields(e, e.zoomBy(framing(inputs.field("framing")), factor: inputs.number("factor")))
        case "FramingSpace.pan_by":
            let e = try space(from: inputs)
            let f = try e.panBy(framing(inputs.field("framing")), dx: inputs.number("dx"), dy: inputs.number("dy"))
            return try fields(e, f)
        case "FramingSpace.between":
            let e = try space(from: inputs)
            let f = try e.between(
                framing(inputs.field("a")), framing(inputs.field("b")),
                elapsedMs: inputs.number("elapsed_ms"), durationMs: inputs.number("duration_ms")
            )
            return try fields(e, f)
        default:
            throw GoldenError.message("fn sin réplica: \(fn)")
        }
    }
}
