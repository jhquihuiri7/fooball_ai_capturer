// El arnés de vectores dorados (IOS-03): lee lo que exporta el servidor con REF-10.
//
// Esquema v1, un fichero por módulo:
//   {schema, module, conventions, cases: [{name, fn, inputs, expected, tol: {abs, rel}}]}
// Escalares con el repr de Python (ida y vuelta exacta a Double) y tensores como
// {dtype: f64|f32|u8|i32, shape, b64} en little-endian y orden C.
//
// Los ficheros los deja `export_golden.py --sync` del servidor en Golden/, junto a
// golden-manifest.json con el sha256 de cada uno y el commit del que salieron. Aquí
// no se regenera nada: si algo no cuadra, el que manda es el servidor.

import CryptoKit
import Foundation

enum GoldenError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(text): return text }
    }
}

struct GoldenTolerance: Decodable, Sendable {
    let abs: Double
    let rel: Double
}

struct GoldenTensor: Equatable, Sendable {
    let dtype: String
    let shape: [Int]
    let data: Data

    var count: Int { shape.reduce(1, *) }

    /// Los valores como Double, decodificados en little-endian (arm64 lo es).
    func doubles() throws -> [Double] {
        switch dtype {
        case "f64":
            return numbers(as: UInt64.self).map { Double(bitPattern: $0) }
        case "f32":
            return numbers(as: UInt32.self).map { Double(Float(bitPattern: $0)) }
        case "i32":
            return numbers(as: UInt32.self).map { Double(Int32(bitPattern: $0)) }
        case "u8":
            return data.map { Double($0) }
        default:
            throw GoldenError.message("dtype desconocido: \(dtype)")
        }
    }

    private func numbers<T: FixedWidthInteger>(as _: T.Type) -> [T] {
        let size = MemoryLayout<T>.size
        return (0..<(data.count / size)).map { index in
            var raw: T = 0
            _ = withUnsafeMutableBytes(of: &raw) {
                data.copyBytes(to: $0, from: (index * size)..<((index + 1) * size))
            }
            return T(littleEndian: raw)
        }
    }
}

/// El JSON del formato, con el tensor como caso propio: es lo único que no es JSON puro.
indirect enum GoldenValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GoldenValue])
    case object([String: GoldenValue])
    case tensor(GoldenTensor)

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let valor = try? single.decode(Bool.self) {
            self = .bool(valor)
        } else if let valor = try? single.decode(Double.self) {
            self = .number(valor)
        } else if let valor = try? single.decode(String.self) {
            self = .string(valor)
        } else if let valor = try? single.decode([GoldenValue].self) {
            self = .array(valor)
        } else {
            let objeto = try single.decode([String: GoldenValue].self)
            if Set(objeto.keys) == ["dtype", "shape", "b64"],
               case let .string(dtype)? = objeto["dtype"],
               case let .array(ejes)? = objeto["shape"],
               case let .string(b64)? = objeto["b64"] {
                guard let data = Data(base64Encoded: b64) else {
                    throw GoldenError.message("b64 ilegible en un tensor \(dtype)")
                }
                let shape = try ejes.map { eje -> Int in
                    guard case let .number(n) = eje else {
                        throw GoldenError.message("shape con algo que no es un número")
                    }
                    return Int(n)
                }
                self = .tensor(GoldenTensor(dtype: dtype, shape: shape, data: data))
            } else {
                self = .object(objeto)
            }
        }
    }
}

struct GoldenCase: Decodable, Sendable {
    let name: String
    let fn: String
    let inputs: GoldenValue
    let expected: GoldenValue
    let tol: GoldenTolerance
}

struct GoldenDocument: Decodable, Sendable {
    let schema: Int
    let module: String
    let conventions: [String: String]
    let cases: [GoldenCase]
}

struct GoldenManifest: Decodable, Sendable {
    let schema: Int
    let warning: String
    let sourceCommit: String
    let files: [String: String]

    enum CodingKeys: String, CodingKey {
        case schema, warning, files
        case sourceCommit = "source_commit"
    }
}

enum Golden {
    /// La versión del formato que esta app sabe leer. Si el servidor la sube, este
    /// número se toca a la vez que la réplica, nunca solo.
    static let expectedSchema = 1

    static func directory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Golden", withExtension: nil) else {
            throw GoldenError.message("no está la carpeta Golden en el bundle de tests")
        }
        return url
    }

    static func loadDocument(named name: String, in folder: URL? = nil) throws -> GoldenDocument {
        let base = try folder ?? directory()
        let data = try Data(contentsOf: base.appendingPathComponent(name))
        let documento = try JSONDecoder().decode(GoldenDocument.self, from: data)
        guard documento.schema == expectedSchema else {
            throw GoldenError.message("\(name): schema \(documento.schema), se esperaba \(expectedSchema)")
        }
        return documento
    }

    static func loadManifest(in folder: URL? = nil) throws -> GoldenManifest {
        let base = try folder ?? directory()
        let data = try Data(contentsOf: base.appendingPathComponent("golden-manifest.json"))
        return try JSONDecoder().decode(GoldenManifest.self, from: data)
    }

    /// Comprueba el manifiesto entero: versión, commit y el sha256 de cada fichero.
    /// Devuelve los nombres verificados, para que el meta-test pueda exigir un mínimo.
    @discardableResult
    static func verifyManifest(in folder: URL? = nil) throws -> [String] {
        let base = try folder ?? directory()
        let manifiesto = try loadManifest(in: base)
        guard manifiesto.schema == expectedSchema else {
            throw GoldenError.message("manifiesto con schema \(manifiesto.schema), se esperaba \(expectedSchema)")
        }
        guard !manifiesto.sourceCommit.isEmpty else {
            throw GoldenError.message("manifiesto sin source_commit")
        }
        for (nombre, esperado) in manifiesto.files.sorted(by: { $0.key < $1.key }) {
            let ruta = base.appendingPathComponent(nombre)
            guard let data = try? Data(contentsOf: ruta) else {
                throw GoldenError.message("falta \(nombre), que el manifiesto promete")
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == esperado else {
                throw GoldenError.message("\(nombre): sha256 \(sha) y el manifiesto dice \(esperado)")
            }
        }
        return manifiesto.files.keys.sorted()
    }

    // MARK: - Comparación con tolerancia

    /// `nil` si cuadra; si no, dónde y por cuánto. El `path` arranca en el nombre del
    /// caso, así que un dorado alterado falla nombrando al culpable.
    static func mismatch(
        actual: GoldenValue,
        expected: GoldenValue,
        tol: GoldenTolerance,
        path: String
    ) -> String? {
        switch (actual, expected) {
        case (.null, .null):
            return nil
        case let (.bool(a), .bool(e)):
            return a == e ? nil : "\(path): \(a) != \(e)"
        case let (.string(a), .string(e)):
            return a == e ? nil : "\(path): \(a) != \(e)"
        case let (.number(a), .number(e)):
            return close(a, e, tol: tol) ? nil : "\(path): \(a) != \(e) (tol \(tol.abs)/\(tol.rel))"
        case let (.array(a), .array(e)):
            guard a.count == e.count else { return "\(path): longitud \(a.count) != \(e.count)" }
            for (indice, par) in zip(a, e).enumerated() {
                if let fallo = mismatch(actual: par.0, expected: par.1, tol: tol, path: "\(path)[\(indice)]") {
                    return fallo
                }
            }
            return nil
        case let (.object(a), .object(e)):
            guard Set(a.keys) == Set(e.keys) else {
                return "\(path): claves \(a.keys.sorted()) != \(e.keys.sorted())"
            }
            for clave in e.keys.sorted() {
                if let fallo = mismatch(actual: a[clave]!, expected: e[clave]!, tol: tol, path: "\(path).\(clave)") {
                    return fallo
                }
            }
            return nil
        case let (.tensor(a), .tensor(e)):
            guard a.dtype == e.dtype else { return "\(path): dtype \(a.dtype) != \(e.dtype)" }
            guard a.shape == e.shape else { return "\(path): shape \(a.shape) != \(e.shape)" }
            guard let va = try? a.doubles(), let ve = try? e.doubles() else {
                return "\(path): tensor ilegible"
            }
            for (indice, par) in zip(va, ve).enumerated() where !close(par.0, par.1, tol: tol) {
                return "\(path): tensor[\(indice)] \(par.0) != \(par.1)"
            }
            return nil
        default:
            return "\(path): tipos distintos"
        }
    }

    /// |a − e| ≤ max(abs, rel·|e|): la misma regla que el pytest del servidor.
    static func close(_ actual: Double, _ expected: Double, tol: GoldenTolerance) -> Bool {
        if actual == expected { return true }
        return abs(actual - expected) <= max(tol.abs, tol.rel * abs(expected))
    }

    /// Para ángulos: la diferencia da la vuelta en ±π antes de compararse, porque
    /// π − ε y −π + ε son la misma dirección y una resta a secas diría que no.
    static func closeAngle(_ actual: Double, _ expected: Double, tol: GoldenTolerance) -> Bool {
        let vuelta = atan2(sin(actual - expected), cos(actual - expected))
        return abs(vuelta) <= max(tol.abs, tol.rel * abs(expected))
    }
}
