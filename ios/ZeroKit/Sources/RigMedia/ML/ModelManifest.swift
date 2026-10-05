// El manifiesto de los modelos del móvil (IOS-22): ios/Runner/Models/manifest.json, el
// espejo del bloque `coreml` de models/registry.yaml (REF-20).
//
// Nada de esto está dentro del .mlpackage y equivocarse no da error: solo hunde el
// score, o cambia las etiquetas en silencio. Por eso se valida al cargar y un modelo que
// no cuadra se rechaza con un error que dice qué campo falla, para el estado.

import CoreML
import Foundation

public struct ModelManifest: Equatable, Sendable {
    public static let fileVersion = 1

    public struct Tensor: Equatable, Sendable {
        public let name: String
        public let shape: [Int]
        /// Qué es la salida: `logits`, `boxes_cxcywh_norm`, `boxes_xyxy_input_px`, `heatmap`…
        public let meaning: String
    }

    public struct Input: Equatable, Sendable {
        public let name: String
        public let shape: [Int]
        public let color: String
        public let scale: Double
        public let mean: [Double]
        public let std: [Double]
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let version: String
        /// El .mlpackage, relativo a la carpeta del manifiesto.
        public let file: String
        public let sha256: String
        public let minIos: Int
        public let input: Input
        public let outputs: [Tensor]
        public let classes: [String]
        public let postprocess: String
        public let boxFormat: String

        public func output(meaning: String) -> Tensor? { outputs.first { $0.meaning == meaning } }
    }

    public let models: [String: Entry]

    public enum ManifestError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            if case let .invalid(m) = self { return m }
            return ""
        }
    }

    public static func load(from url: URL) throws -> ModelManifest {
        let datos = try Data(contentsOf: url)
        guard let raiz = try JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
            throw ManifestError.invalid("manifest.json no es un objeto")
        }
        return try parse(raiz)
    }

    public static func parse(_ raiz: [String: Any]) throws -> ModelManifest {
        guard raiz["version"] as? Int == fileVersion else {
            throw ManifestError.invalid("manifiesto de versión \(raiz["version"] ?? "?"), se esperaba \(fileVersion)")
        }
        guard let modelos = raiz["models"] as? [String: Any] else {
            throw ManifestError.invalid("falta `models`")
        }
        var salida: [String: Entry] = [:]
        for (nombre, crudo) in modelos {
            guard let m = crudo as? [String: Any] else { throw ManifestError.invalid("\(nombre): no es un objeto") }
            salida[nombre] = try entry(nombre, m)
        }
        return ModelManifest(models: salida)
    }

    private static func entry(_ n: String, _ m: [String: Any]) throws -> Entry {
        func texto(_ k: String, _ d: [String: Any] = m, _ sitio: String? = nil) throws -> String {
            guard let v = d[k] as? String, !v.isEmpty else {
                throw ManifestError.invalid("\(sitio ?? n): falta `\(k)`")
            }
            return v
        }
        func forma(_ d: [String: Any], _ sitio: String) throws -> [Int] {
            guard let s = d["shape"] as? [Int], !s.isEmpty, s.allSatisfy({ $0 > 0 }) else {
                throw ManifestError.invalid("\(sitio): `shape` tiene que ser una lista de enteros positivos")
            }
            return s
        }
        guard let entrada = m["input"] as? [String: Any] else { throw ManifestError.invalid("\(n): falta `input`") }
        let sitioIn = "\(n).input"
        let input = Input(
            name: try texto("name", entrada, sitioIn), shape: try forma(entrada, sitioIn),
            color: try texto("color", entrada, sitioIn),
            scale: (entrada["scale"] as? NSNumber)?.doubleValue ?? 1,
            mean: (entrada["mean"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0],
            std: (entrada["std"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1, 1]
        )
        guard ["RGB", "BGR"].contains(input.color) else {
            throw ManifestError.invalid("\(sitioIn): `color` tiene que ser RGB o BGR, no \(input.color)")
        }
        guard let crudas = m["outputs"] as? [[String: Any]], !crudas.isEmpty else {
            throw ManifestError.invalid("\(n): faltan `outputs`")
        }
        let outputs = try crudas.enumerated().map { i, o in
            Tensor(name: try texto("name", o, "\(n).outputs[\(i)]"), shape: try forma(o, "\(n).outputs[\(i)]"),
                   meaning: try texto("meaning", o, "\(n).outputs[\(i)]"))
        }
        guard let clases = m["classes"] as? [String], !clases.isEmpty else {
            throw ManifestError.invalid("\(n): faltan `classes` (su orden cambia las etiquetas en silencio)")
        }
        if let logits = outputs.first(where: { $0.meaning == "logits" }), logits.shape.last != clases.count {
            throw ManifestError.invalid(
                "\(n): los logits tienen \(logits.shape.last ?? 0) clases y `classes` lista \(clases.count)"
            )
        }
        guard let minIos = m["min_ios"] as? Int, minIos >= 18 else {
            throw ManifestError.invalid("\(n): `min_ios` tiene que ser ≥18")
        }
        let sha = try texto("sha256")
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
            throw ManifestError.invalid("\(n): `sha256` no es un SHA-256 en hexadecimal")
        }
        return Entry(
            name: n, version: try texto("version"), file: try texto("file"), sha256: sha.lowercased(),
            minIos: minIos, input: input, outputs: outputs, classes: clases,
            postprocess: (m["postprocess"] as? String) ?? "detr",
            boxFormat: (m["box_format"] as? String) ?? "cxcywh_norm"
        )
    }
}

extension ModelManifest.Entry {
    /// Comprueba que el modelo cargado dice lo mismo que el manifiesto: los nombres de la
    /// entrada y de las salidas, y sus formas. Un manifiesto de otro modelo no pasa.
    public func check(against description: MLModelDescription) throws {
        guard let entrada = description.inputDescriptionsByName[input.name] else {
            throw ModelManifest.ManifestError.invalid(
                "\(name): el modelo no tiene la entrada `\(input.name)` (tiene \(description.inputDescriptionsByName.keys.sorted()))"
            )
        }
        if let img = entrada.imageConstraint {
            let (w, h) = (input.shape.last ?? 0, input.shape.count >= 2 ? input.shape[input.shape.count - 2] : 0)
            guard img.pixelsWide == w, img.pixelsHigh == h else {
                throw ModelManifest.ManifestError.invalid(
                    "\(name): la entrada es \(img.pixelsWide)×\(img.pixelsHigh) y el manifiesto dice \(w)×\(h)"
                )
            }
        }
        for o in outputs {
            guard let d = description.outputDescriptionsByName[o.name] else {
                throw ModelManifest.ManifestError.invalid("\(name): el modelo no tiene la salida `\(o.name)`")
            }
            if let forma = d.multiArrayConstraint?.shape.map(\.intValue), !forma.isEmpty, forma != o.shape {
                throw ModelManifest.ManifestError.invalid(
                    "\(name): la salida `\(o.name)` es \(forma) y el manifiesto dice \(o.shape)"
                )
            }
        }
    }
}
