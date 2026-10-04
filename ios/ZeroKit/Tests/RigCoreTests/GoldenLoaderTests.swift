import XCTest

@testable import RigCore

/// El arnés de dorados (IOS-03): que lee lo que el servidor exporta, que compara con
/// la tolerancia declarada y que el manifiesto no deja pasar un fichero cambiado.
final class GoldenLoaderTests: XCTestCase {
    // MARK: - El manifiesto

    func testTheRealManifestVerifies() throws {
        let verificados = try Golden.verifyManifest()
        // Los siete módulos de REF-11…13 más el manifest.json del propio directorio.
        XCTAssertGreaterThanOrEqual(verificados.count, 8)
        XCTAssertTrue(verificados.contains("rig.json"))
    }

    func testAWrongShaIsRejected() throws {
        let carpeta = try temporaryGoldenFolder(
            manifest: #"{"schema": 1, "warning": "x", "source_commit": "abc", "files": {"a.json": "0000"}}"#,
            files: ["a.json": "{}"]
        )
        XCTAssertThrowsError(try Golden.verifyManifest(in: carpeta)) { error in
            XCTAssertTrue("\(error)".contains("a.json"))
            XCTAssertTrue("\(error)".contains("sha256"))
        }
    }

    func testAMissingFileIsRejected() throws {
        let carpeta = try temporaryGoldenFolder(
            manifest: #"{"schema": 1, "warning": "x", "source_commit": "abc", "files": {"no-esta.json": "00"}}"#,
            files: [:]
        )
        XCTAssertThrowsError(try Golden.verifyManifest(in: carpeta)) { error in
            XCTAssertTrue("\(error)".contains("no-esta.json"))
        }
    }

    func testAnUnsupportedSchemaIsRejected() throws {
        let carpeta = try temporaryGoldenFolder(
            manifest: #"{"schema": 2, "warning": "x", "source_commit": "abc", "files": {}}"#,
            files: [:]
        )
        XCTAssertThrowsError(try Golden.verifyManifest(in: carpeta)) { error in
            XCTAssertTrue("\(error)".contains("schema 2"))
        }
    }

    // MARK: - Los documentos reales

    func testEveryDocumentInTheManifestParses() throws {
        let manifiesto = try Golden.loadManifest()
        var casos = 0
        for nombre in manifiesto.files.keys.sorted() where nombre != "manifest.json" {
            // La muestra del N0 (EV-02) es JSONL, no un documento de casos: cada
            // línea tiene que ser un objeto JSON, y la primera, la cabecera.
            if nombre.hasSuffix(".jsonl") {
                let url = try Golden.directory().appendingPathComponent(nombre)
                let texto = try String(contentsOf: url, encoding: .utf8)
                for linea in texto.split(separator: "\n") {
                    let objeto = try JSONSerialization.jsonObject(with: Data(linea.utf8))
                    XCTAssertTrue(objeto is [String: Any], "\(nombre): línea que no es objeto")
                }
                continue
            }
            let documento = try Golden.loadDocument(named: nombre)
            XCTAssertEqual(documento.schema, 1, nombre)
            XCTAssertEqual("\(documento.module).json", nombre)
            XCTAssertFalse(documento.conventions.isEmpty, nombre)
            casos += documento.cases.count
        }
        // REF-11…13 suman más de sesenta; si esto baja, el sync trajo medio directorio.
        XCTAssertGreaterThanOrEqual(casos, 60)
    }

    func testARealGoldenCasePassesAgainstItself() throws {
        let rig = try Golden.loadDocument(named: "rig.json")
        let caso = try XCTUnwrap(rig.cases.first { $0.name == "matrix_izquierda_invertida" })

        XCTAssertNil(Golden.mismatch(actual: caso.expected, expected: caso.expected, tol: caso.tol, path: caso.name))
    }

    func testAlteringAValueFailsNamingTheCase() throws {
        let rig = try Golden.loadDocument(named: "rig.json")
        let caso = try XCTUnwrap(rig.cases.first { $0.name == "ultra_gran_angular_4k" })
        guard case var .object(campos) = caso.expected,
              case let .number(fx)? = campos["fx"]
        else {
            return XCTFail("el expected de from_hfov ya no es un objeto con fx")
        }
        campos["fx"] = .number(fx + 0.5)

        let fallo = Golden.mismatch(
            actual: .object(campos), expected: caso.expected, tol: caso.tol, path: caso.name
        )

        let mensaje = try XCTUnwrap(fallo)
        XCTAssertTrue(mensaje.contains("ultra_gran_angular_4k"))
        XCTAssertTrue(mensaje.contains("fx"))
    }

    func testTensorsDecodeExactly() throws {
        let rig = try Golden.loadDocument(named: "rig.json")
        let caso = try XCTUnwrap(rig.cases.first { $0.name == "matrix_derecha_nominal" })
        guard case let .object(campos) = caso.expected, case let .tensor(matriz)? = campos["matrix"] else {
            return XCTFail("matrix no es un tensor")
        }

        XCTAssertEqual(matriz.dtype, "f64")
        XCTAssertEqual(matriz.shape, [3, 3])
        let valores = try matriz.doubles()
        XCTAssertEqual(valores.count, 9)
        // Una rotación: cada fila es unitaria. Lo justo para saber que los bytes
        // llegaron enteros; la paridad de verdad la harán las réplicas.
        for fila in 0..<3 {
            let norma = (0..<3).map { valores[fila * 3 + $0] * valores[fila * 3 + $0] }.reduce(0, +)
            XCTAssertEqual(norma, 1.0, accuracy: 1e-12)
        }
    }

    // MARK: - Tolerancias y ángulos

    func testToleranceIsAbsoluteAndRelative() {
        let tol = GoldenTolerance(abs: 1e-9, rel: 1e-9)
        XCTAssertTrue(Golden.close(1.0 + 5e-10, 1.0, tol: tol))
        XCTAssertFalse(Golden.close(1.0 + 5e-8, 1.0, tol: tol))
        // Con magnitud grande manda la relativa: 1e5 · 1e-9 = 1e-4 de margen.
        XCTAssertTrue(Golden.close(100_000.00005, 100_000.0, tol: tol))
        XCTAssertFalse(Golden.close(100_000.001, 100_000.0, tol: tol))
    }

    func testAnglesWrapAtPi() {
        let tol = GoldenTolerance(abs: 1e-9, rel: 0)
        // π − ε y −π + ε son la misma dirección con 2ε de separación real: la
        // comparación angular lo ve y la resta a secas diría que están a 2π.
        let casiPi = Double.pi - 2e-10
        XCTAssertTrue(Golden.closeAngle(casiPi, -Double.pi + 2e-10, tol: tol))
        XCTAssertFalse(Golden.close(casiPi, -Double.pi + 2e-10, tol: tol))
        XCTAssertFalse(Golden.closeAngle(1.0, 1.1, tol: tol))
    }

    // MARK: - Soporte

    private func temporaryGoldenFolder(manifest: String, files: [String: String]) throws -> URL {
        let carpeta = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: carpeta) }
        try manifest.write(to: carpeta.appendingPathComponent("golden-manifest.json"), atomically: true, encoding: .utf8)
        for (nombre, contenido) in files {
            try contenido.write(to: carpeta.appendingPathComponent(nombre), atomically: true, encoding: .utf8)
        }
        return carpeta
    }
}
