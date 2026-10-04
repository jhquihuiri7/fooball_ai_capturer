// La homografía del campo contra los dorados de pitch.json (IOS-36).
//
// El ajuste (`from_correspondences`, RANSAC) se queda en Python A PROPÓSITO: el
// móvil solo aplica. Por eso el runner no ajusta nada: construye el modelo desde la
// `h` ESPERADA del dorado —los mismos bits f64 que resolvió el VPS— y verifica que
// aplicarla a las consultas da los metros y los píxeles dorados. Eso es exactamente
// lo que hará la app con el pitch.json descargado.

import Foundation
import RigCore
import XCTest

final class PitchModelTests: XCTestCase {
    func testLosDoradosDePitch() throws {
        let documento = try Golden.loadDocument(named: "pitch.json")
        var corridos = 0
        for caso in documento.cases {
            switch caso.fn {
            case "PitchModel.from_correspondences":
                try verificaAplicacion(caso)
            case "RigPitchModel.from_correspondences":
                try verificaSoporte(caso)
            default:
                XCTFail("fn sin réplica en pitch.json: \(caso.fn)")
            }
            corridos += 1
        }
        XCTAssertGreaterThanOrEqual(corridos, 2, "pitch.json trae al menos los dos ajustes")
    }

    /// Una cámara: la `h` dorada aplicada en los dos sentidos reproduce las
    /// consultas del dorado. El error de ajuste y los descartes son del VPS.
    private func verificaAplicacion(_ caso: GoldenCase) throws {
        let modelo = try PitchModel(
            homography: Self.matriz(de: try caso.expected.field("h")),
            pitchLengthM: try caso.inputs.number("pitch_length_m"),
            pitchWidthM: try caso.inputs.number("pitch_width_m")
        )

        var aMetros: [GoldenValue] = []
        for (x, y) in try Self.pares(caso.inputs, "queries_px") {
            let metros = try modelo.imageToPitch(xPx: x, yPx: y)
            aMetros.append(.array([.number(metros.x), .number(metros.y)]))
        }
        if let fallo = Golden.mismatch(
            actual: .array(aMetros),
            expected: try caso.expected.field("image_to_pitch"),
            tol: caso.tol,
            path: "\(caso.name).image_to_pitch"
        ) {
            XCTFail(fallo)
        }

        var aPixeles: [GoldenValue] = []
        for (x, y) in try Self.pares(caso.inputs, "queries_m") {
            let pixeles = try modelo.pitchToImage(xM: x, yM: y)
            aPixeles.append(.array([.number(pixeles.x), .number(pixeles.y)]))
        }
        if let fallo = Golden.mismatch(
            actual: .array(aPixeles),
            expected: try caso.expected.field("pitch_to_image"),
            tol: caso.tol,
            path: "\(caso.name).pitch_to_image"
        ) {
            XCTFail(fallo)
        }
    }

    /// Las dos cámaras: los errores cruzados de los puntos compartidos salen de las
    /// homografías doradas, no del fichero, y tienen que dar los del dorado.
    private func verificaSoporte(_ caso: GoldenCase) throws {
        let soporte = try RigPitchModel(
            left: PitchModel(
                homography: Self.matriz(de: try caso.expected.field("left_h")),
                pitchLengthM: try caso.inputs.number("pitch_length_m"),
                pitchWidthM: try caso.inputs.number("pitch_width_m")
            ),
            right: PitchModel(
                homography: Self.matriz(de: try caso.expected.field("right_h")),
                pitchLengthM: try caso.inputs.number("pitch_length_m"),
                pitchWidthM: try caso.inputs.number("pitch_width_m")
            ),
            sharedPoints: try Self.compartidos(caso.inputs)
        )

        var errores: [GoldenValue] = []
        for punto in soporte.sharedPoints {
            errores.append(.number(try soporte.crossCameraErrorM(punto)))
        }
        if let fallo = Golden.mismatch(
            actual: .number(try soporte.meanCrossCameraErrorM(soporte.sharedPoints)),
            expected: try caso.expected.field("mean_cross_camera_error_m"),
            tol: caso.tol,
            path: "\(caso.name).mean_cross_camera_error_m"
        ) {
            XCTFail(fallo)
        }
        if let fallo = Golden.mismatch(
            actual: .array(errores),
            expected: try caso.expected.field("cross_errors_m"),
            tol: caso.tol,
            path: "\(caso.name).cross_errors_m"
        ) {
            XCTFail(fallo)
        }
    }

    // MARK: - El álgebra nueva de Mat3

    func testLaInversaDeshaceLaIda() throws {
        let modelo = try Self.modeloDorado()
        let identidad = try modelo.homography.inverted().multiplied(by: modelo.homography)
        for fila in 0..<3 {
            for columna in 0..<3 {
                XCTAssertEqual(
                    identidad[fila, columna], fila == columna ? 1 : 0, accuracy: 1e-12
                )
            }
        }
        XCTAssertEqual(Mat3.identity.determinant, 1)
        XCTAssertEqual(Mat3.identity.frobeniusNorm, 3.0.squareRoot())
        XCTAssertThrowsError(
            try Mat3(rows: [1, 2, 3, 2, 4, 6, 0, 0, 1]).inverted()
        )
    }

    // MARK: - Validaciones del códec, como en la referencia

    func testOtraVersionDePitchJsonSeRechaza() {
        XCTAssertThrowsError(try PitchModel.fromDictionary(["version": 2]))
        XCTAssertThrowsError(try PitchModel.fromDictionary([:]))
        XCTAssertThrowsError(try RigPitchModel.fromDictionary(["version": 2]))
    }

    func testUnaHomografiaSingularSeRechaza() {
        // Rango 2: la segunda fila es el doble de la primera.
        XCTAssertThrowsError(
            try PitchModel(homography: Mat3(rows: [1, 2, 3, 2, 4, 6, 0, 0, 1]))
        ) { error in
            XCTAssertTrue("\(error)".contains("no es invertible"))
        }
    }

    func testElHorizonteNoTieneImagenFinita() throws {
        // w = −y + 1 al volver del plano imagen: la fila y = 1 es el horizonte.
        let modelo = try PitchModel(homography: Mat3(rows: [1, 0, 0, 0, 1, 0, 0, 1, 1]))
        XCTAssertThrowsError(try modelo.imageToPitch(xPx: 7, yPx: 1)) { error in
            XCTAssertTrue("\(error)".contains("horizonte"))
        }
        // El filtro no lanza: lo que no tiene proyección finita no pisa el campo.
        XCTAssertFalse(modelo.isInsidePlayable(xPx: 7, yPx: 1))
    }

    func testCanchasDistintasSeRechazan() throws {
        let h = try Self.modeloDorado().homography
        let izquierda = try PitchModel(homography: h)
        let derecha = try PitchModel(homography: h, pitchWidthM: 64)
        XCTAssertThrowsError(try RigPitchModel(left: izquierda, right: derecha)) { error in
            XCTAssertTrue("\(error)".contains("canchas distintas"))
        }
    }

    func testElCodecIdaYVuelta() throws {
        let modelo = try Self.modeloDorado()
        let soporte = try RigPitchModel(
            left: modelo,
            right: modelo,
            sharedPoints: [
                SharedGroundPoint(leftXPx: 1500, leftYPx: 1100, rightXPx: 1500, rightYPx: 1100)
            ]
        )
        let plano = try soporte.toDictionary()
        let leido = try RigPitchModel.fromDictionary(plano)

        XCTAssertEqual(leido.left.homography, soporte.left.homography)
        XCTAssertEqual(leido.right.homography, soporte.right.homography)
        XCTAssertEqual(leido.sharedPoints, soporte.sharedPoints)
        XCTAssertEqual(leido.left.pitchLengthM, soporte.left.pitchLengthM)
        // El cross_error_m escrito se recalcula de las homografías al leer; con la
        // misma H a cada lado y el mismo píxel, el desacuerdo es exactamente cero.
        XCTAssertEqual(try leido.crossCameraErrorM(leido.sharedPoints[0]), 0)
    }

    // MARK: - El filtro contra la máscara de mapa de bits

    /// La aceptación de IOS-36: el polígono con margen da lo mismo que la máscara de
    /// §14.2. La máscara se rasteriza aquí como la define el blueprint —en cada píxel,
    /// ¿su proyección a metros cae en el área jugable?— y el pie continuo se trunca a
    /// píxel como hace player_detector (clip + astype). Donde el vecindario 3×3 del
    /// píxel es unánime, el muestreo no puede cambiar la respuesta y las dos rutas
    /// tienen que coincidir; las celdas de frontera, donde la máscara se juega su
    /// propio píxel de cuantización, se cuentan y tienen que ser raras.
    func testElFiltroCoincideConLaMascara() throws {
        let modelo = try Self.modeloDorado()
        let ancho = 3840.0
        let alto = 2160.0

        func mascara(_ xPx: Int, _ yPx: Int) -> Bool {
            modelo.isInsidePlayable(xPx: Double(xPx), yPx: Double(yPx))
        }

        var comparados = 0
        var frontera = 0
        var dentro = 0
        for paso in stride(from: 0.0, to: alto, by: 48.0) {
            for columna in stride(from: 0.0, to: ancho, by: 48.0) {
                for (dx, dy) in [(0.3, 0.7), (0.8, 0.2)] {
                    let pie = (x: columna + dx, y: paso + dy)
                    let xTruncada = Int(min(max(pie.x, 0), ancho - 1))
                    let yTruncada = Int(min(max(pie.y, 0), alto - 1))
                    let centro = mascara(xTruncada, yTruncada)

                    var unanime = true
                    for vx in -1...1 {
                        for vy in -1...1 where mascara(xTruncada + vx, yTruncada + vy) != centro {
                            unanime = false
                        }
                    }
                    guard unanime else {
                        frontera += 1
                        continue
                    }
                    XCTAssertEqual(
                        modelo.isInsidePlayable(xPx: pie.x, yPx: pie.y),
                        centro,
                        "pie (\(pie.x), \(pie.y)): el polígono y la máscara no coinciden"
                    )
                    comparados += 1
                    if centro { dentro += 1 }
                }
            }
        }
        // Que la comparación haya mordido de verdad: miles de pies, de los dos lados
        // del borde, y la frontera por debajo del 5% de las celdas.
        XCTAssertGreaterThan(comparados, 5_000)
        XCTAssertGreaterThan(dentro, 500)
        XCTAssertGreaterThan(comparados - dentro, 500)
        XCTAssertLessThan(Double(frontera), 0.05 * Double(comparados + frontera))
    }

    // MARK: - Lectura de los dorados

    /// El modelo de la cámara única de pitch.json: la `h` que resolvió el VPS.
    private static func modeloDorado() throws -> PitchModel {
        let documento = try Golden.loadDocument(named: "pitch.json")
        guard let caso = documento.cases.first(
            where: { $0.fn == "PitchModel.from_correspondences" }
        ) else {
            throw GoldenError.message("pitch.json ya no trae el caso de una cámara")
        }
        return try PitchModel(
            homography: matriz(de: try caso.expected.field("h")),
            pitchLengthM: try caso.inputs.number("pitch_length_m"),
            pitchWidthM: try caso.inputs.number("pitch_width_m")
        )
    }

    private static func matriz(de valor: GoldenValue) throws -> Mat3 {
        guard let tensor = valor.tensorValue, tensor.shape == [3, 3] else {
            throw GoldenError.message("la homografia dorada no es un tensor 3x3")
        }
        return Mat3(rows: try tensor.doubles())
    }

    private static func pares(
        _ inputs: GoldenValue, _ clave: String
    ) throws -> [(Double, Double)] {
        guard case let .array(crudos)? = try? inputs.field(clave) else {
            throw GoldenError.message("\(clave) no es una lista")
        }
        return try crudos.map { crudo in
            guard case let .array(par) = crudo, par.count == 2,
                  let x = par[0].numberValue, let y = par[1].numberValue
            else {
                throw GoldenError.message("\(clave) lleva un elemento que no es [x, y]")
            }
            return (x, y)
        }
    }

    private static func compartidos(_ inputs: GoldenValue) throws -> [SharedGroundPoint] {
        guard case let .array(crudos)? = try? inputs.field("shared") else {
            throw GoldenError.message("shared no es una lista")
        }
        return try crudos.map { crudo in
            guard case let .array(izquierda)? = try? crudo.field("left_xy_px"),
                  case let .array(derecha)? = try? crudo.field("right_xy_px"),
                  izquierda.count == 2, derecha.count == 2,
                  let lx = izquierda[0].numberValue, let ly = izquierda[1].numberValue,
                  let rx = derecha[0].numberValue, let ry = derecha[1].numberValue
            else {
                throw GoldenError.message("un punto compartido no lleva [x, y] por lado")
            }
            return SharedGroundPoint(leftXPx: lx, leftYPx: ly, rightXPx: rx, rightYPx: ry)
        }
    }
}
