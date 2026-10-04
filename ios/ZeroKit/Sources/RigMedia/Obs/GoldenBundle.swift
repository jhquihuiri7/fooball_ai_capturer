// El lector del bundle dorado de ML-12 (SPK-50).
//
// El bundle lo genera tools/golden.py del repo de entrenamiento: manifest.json con
// formas, dtype, layout y la tolerancia OBLIGATORIA por salida y por ruta, y arrays
// .bin little-endian en orden C. Los nombres llevan la muestra como sufijo _NNN
// (image_000, logits_000...): aquí se separa base y muestra para casarlos con los
// nombres de las features del modelo.

import Foundation

public struct GoldenItem: Decodable {
    public let name: String
    public let file: String
    public let dtype: String
    public let shape: [Int]
    public let layout: String

    /// "image_000" -> ("image", 0). Sin sufijo numérico no hay muestra.
    public var baseAndSample: (base: String, sample: Int)? {
        guard let corte = name.lastIndex(of: "_"),
              let muestra = Int(name[name.index(after: corte)...])
        else { return nil }
        return (String(name[..<corte]), muestra)
    }

    public var count: Int { shape.reduce(1, *) }
}

public struct GoldenManifest: Decodable {
    public let version: Int
    public let model: String
    public let modelVersion: String
    public let inputs: [GoldenItem]
    public let outputs: [String: [GoldenItem]]
    public let tolerances: [String: [String: Double]]

    enum CodingKeys: String, CodingKey {
        case version, model, inputs, outputs, tolerances
        case modelVersion = "model_version"
    }
}

public enum GoldenBundleError: Error, CustomStringConvertible {
    case badVersion(Int)
    case badSize(name: String, expected: Int, got: Int)
    case unknownDtype(String)
    case missingTolerance(output: String, route: String)

    public var description: String {
        switch self {
        case let .badVersion(v): return "manifest version \(v): este lector lee la 1"
        case let .badSize(name, esperado, visto):
            return "\(name): esperaba \(esperado) bytes y hay \(visto)"
        case let .unknownDtype(d): return "dtype \(d) fuera del formato"
        case let .missingTolerance(salida, ruta):
            return "falta la tolerancia de \(salida) por \(ruta)"
        }
    }
}

public struct GoldenBundle {
    public let dir: URL
    public let manifest: GoldenManifest

    public init(dir: URL) throws {
        self.dir = dir
        let datos = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        manifest = try JSONDecoder().decode(GoldenManifest.self, from: datos)
        guard manifest.version == 1 else {
            throw GoldenBundleError.badVersion(manifest.version)
        }
    }

    public func data(_ item: GoldenItem) throws -> Data {
        let crudo = try Data(contentsOf: dir.appendingPathComponent(item.file))
        let esperado = item.count * bytesPerElement(item.dtype)
        guard crudo.count == esperado else {
            throw GoldenBundleError.badSize(name: item.name, expected: esperado, got: crudo.count)
        }
        return crudo
    }

    /// Cualquier dtype del formato, a Float. Little-endian en orden C, como el manifest.
    public func floats(_ item: GoldenItem) throws -> [Float] {
        let datos = try data(item)
        switch item.dtype {
        case "<f4":
            return datos.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        case "<f2":
            return datos.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) }
        case "|u1":
            return datos.map(Float.init)
        case "<i4":
            return datos.withUnsafeBytes { $0.bindMemory(to: Int32.self).map(Float.init) }
        default:
            throw GoldenBundleError.unknownDtype(item.dtype)
        }
    }

    /// Las muestras del bundle, por los sufijos _NNN de sus entradas.
    public var sampleIndices: [Int] {
        Array(Set(manifest.inputs.compactMap { $0.baseAndSample?.sample })).sorted()
    }

    public func input(base: String, sample: Int) -> GoldenItem? {
        manifest.inputs.first { $0.baseAndSample ?? ("", -1) == (base, sample) }
    }

    public func inputBases(sample: Int) -> [String] {
        manifest.inputs.compactMap { item in
            guard let par = item.baseAndSample, par.sample == sample else { return nil }
            return par.base
        }.sorted()
    }

    public func output(route: String, base: String, sample: Int) -> GoldenItem? {
        manifest.outputs[route]?.first { $0.baseAndSample ?? ("", -1) == (base, sample) }
    }

    public func outputBases(route: String, sample: Int) -> [String] {
        (manifest.outputs[route] ?? []).compactMap { item in
            guard let par = item.baseAndSample, par.sample == sample else { return nil }
            return par.base
        }.sorted()
    }

    /// La tolerancia es OBLIGATORIA: que falte es un bundle roto, no un «sin límite».
    public func tolerance(outputName: String, route: String) throws -> Double {
        guard let valor = tolerances(outputName)[route] else {
            throw GoldenBundleError.missingTolerance(output: outputName, route: route)
        }
        return valor
    }

    private func tolerances(_ outputName: String) -> [String: Double] {
        manifest.tolerances[outputName] ?? [:]
    }

    private func bytesPerElement(_ dtype: String) -> Int {
        switch dtype {
        case "<f4", "<i4": return 4
        case "<f2": return 2
        case "|u1": return 1
        default: return 1
        }
    }
}
