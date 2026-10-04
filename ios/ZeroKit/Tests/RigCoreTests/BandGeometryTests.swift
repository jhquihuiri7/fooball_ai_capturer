// La franja jugable contra los dorados de REF (IOS-20): la ida y vuelta de InputLayout
// (postprocess.json) y el band.json de la calibración a 6 y 10 m de retranqueo
// (band.json).

import Foundation
import RigCore
import XCTest

final class BandGeometryTests: XCTestCase {
    func testLaIdaYVueltaDeInputLayout() throws {
        let documento = try Golden.loadDocument(named: "postprocess.json")
        var corridos = 0
        for caso in documento.cases where caso.fn == "InputLayout.map" {
            corridos += 1
            let layout = try Self.layout(caso.inputs.field("layout"))
            guard case let .array(puntos)? = try? caso.inputs.field("points_input") else {
                throw GoldenError.message("points_input no es una lista")
            }
            var regiones: [Int32] = []
            var nativos: [Double] = []
            var vuelta: [Double] = []
            for punto in puntos {
                guard case let .array(xy) = punto, let x = xy[0].numberValue, let y = xy[1].numberValue else {
                    throw GoldenError.message("un punto no es [x, y]")
                }
                let i = layout.regionIndex(xInput: x, yInput: y)
                let region = layout.regions[i]
                let n = region.toNative(xInput: x, yInput: y)
                let b = region.toInput(xNative: n.x, yNative: n.y)
                regiones.append(Int32(i))
                nativos += [n.x, n.y]
                vuelta += [b.x, b.y]
            }
            let actual: GoldenValue = .object([
                "region": .tensor(i32: regiones, shape: [regiones.count]),
                "native": .tensor(f64: nativos, shape: [regiones.count, 2]),
                "back_to_input": .tensor(f64: vuelta, shape: [regiones.count, 2]),
            ])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridos, 3)
    }

    func testLaFranjaDeLaCalibracionA6Y10Metros() throws {
        let documento = try Golden.loadDocument(named: "band.json")
        var porNombre: [String: BandGeometry] = [:]
        for caso in documento.cases where caso.fn == "band_from_pitch" {
            guard let crudo = try caso.expected.field("band").jsonObject() as? [String: Any] else {
                throw GoldenError.message("band no es un objeto")
            }
            let banda = try BandGeometry.fromDictionary(crudo)
            porNombre[caso.name] = banda
            // Ida y vuelta del códec: lo que se escribe es lo que se leyó.
            if let fallo = Golden.mismatch(
                actual: GoldenValue.from(json: banda.toDictionary()),
                expected: try caso.expected.field("band"), tol: caso.tol, path: "\(caso.name).band"
            ) {
                XCTFail(fallo)
            }
            guard case let .array(filas)? = try? caso.inputs.field("rows_px") else {
                throw GoldenError.message("rows_px no es una lista")
            }
            let escalas = filas.compactMap(\.numberValue).map { banda.scaleAtRow($0) }
            if let fallo = Golden.mismatch(
                actual: .tensor(f64: escalas, shape: [escalas.count]),
                expected: try caso.expected.field("scale_at_row"), tol: caso.tol,
                path: "\(caso.name).scale_at_row"
            ) {
                XCTFail(fallo)
            }
        }
        // A 10 m cabe a ×0,5 en una región; a 6 m sale el mosaico.
        let diez = try XCTUnwrap(porNombre["franja_a_10_m_de_retranqueo"])
        XCTAssertEqual(diez.layout.regions.count, 1)
        XCTAssertNil(diez.farSplitRow)
        XCTAssertEqual(diez.scaleAtRow(1200), 1 / DetectionSpec.playerBandScale, accuracy: 1e-12)
        let seis = try XCTUnwrap(porNombre["franja_a_6_m_de_retranqueo"])
        XCTAssertEqual(seis.layout.regions.count, 2)
        XCTAssertNotNil(seis.farSplitRow)
        XCTAssertEqual(seis.side, .right)
    }

    func testLaIdaYVueltaConElGiroCierra() throws {
        let banda = try Self.franjaDiez()
        let (ancho, alto) = (3840, 2160)
        for (x, y) in [(0.0, 0.0), (960.5, 200.25), (1919.0, 399.0)] {
            let crudo = banda.toRaw(xInput: x, yInput: y, nativeWidth: ancho, nativeHeight: alto, upsideDown: true)
            // Del crudo al enderezado es el mismo giro; de ahí, a la entrada.
            let derecho = CameraMount.uprightPoint(x: crudo.x, y: crudo.y, width: ancho, height: alto)
            let region = banda.layout.regions[0]
            let vuelta = region.toInput(xNative: derecho.x, yNative: derecho.y)
            XCTAssertEqual(vuelta.x, x, accuracy: 1e-9)
            XCTAssertEqual(vuelta.y, y, accuracy: 1e-9)
        }
        // Sin giro, el crudo es el nativo.
        let recto = banda.toRaw(xInput: 10, yInput: 10, nativeWidth: ancho, nativeHeight: alto, upsideDown: false)
        XCTAssertEqual(recto.x, 20, accuracy: 1e-12)
        XCTAssertEqual(recto.y, 970 + 20, accuracy: 1e-12)
    }

    func testRechazaLoQueNoCabeEnElDetector() throws {
        var datos = try Self.franjaDiez().toDictionary()
        datos["input_size"] = [1280, 576]
        XCTAssertThrowsError(try BandGeometry.fromDictionary(datos))

        var fuera = try Self.franjaDiez().toDictionary()
        fuera["regions"] = [["dst": [0, 400, 1920, 400], "src": [0.0, 970.0, 3840.0, 800.0]]]
        XCTAssertThrowsError(try BandGeometry.fromDictionary(fuera)) { error in
            XCTAssertTrue("\(error)".contains("se sale"), "\(error)")
        }

        var version = try Self.franjaDiez().toDictionary()
        version["version"] = 2
        XCTAssertThrowsError(try BandGeometry.fromDictionary(version))

        var booleano = try Self.franjaDiez().toDictionary()
        booleano["far_split_row"] = true
        XCTAssertThrowsError(try BandGeometry.fromDictionary(booleano))
    }

    func testUnaRegionQueDeformaSeRechaza() {
        XCTAssertThrowsError(
            try InputRegion(dstX: 0, dstY: 0, dstW: 100, dstH: 100, srcX: 0, srcY: 0, srcW: 200, srcH: 210)
        ) { error in
            XCTAssertTrue("\(error)".contains("deforma"))
        }
        XCTAssertThrowsError(try InputLayout(regions: []))
    }

    // MARK: - Soporte

    private static func franjaDiez() throws -> BandGeometry {
        let documento = try Golden.loadDocument(named: "band.json")
        guard let caso = documento.cases.first(where: { $0.name == "franja_a_10_m_de_retranqueo" }),
              let crudo = try caso.expected.field("band").jsonObject() as? [String: Any]
        else {
            throw GoldenError.message("falta la franja a 10 m en band.json")
        }
        return try BandGeometry.fromDictionary(crudo)
    }

    private static func layout(_ valor: GoldenValue) throws -> InputLayout {
        guard case let .array(crudas)? = try? valor.field("regions") else {
            throw GoldenError.message("regions no es una lista")
        }
        return try InputLayout(regions: crudas.map { cruda in
            guard case let .array(dst)? = try? cruda.field("dst"),
                  case let .array(src)? = try? cruda.field("src")
            else {
                throw GoldenError.message("una región sin dst o src")
            }
            let d = dst.compactMap(\.numberValue), s = src.compactMap(\.numberValue)
            return try InputRegion(
                dstX: Int(d[0]), dstY: Int(d[1]), dstW: Int(d[2]), dstH: Int(d[3]),
                srcX: s[0], srcY: s[1], srcW: s[2], srcH: s[3]
            )
        })
    }
}
