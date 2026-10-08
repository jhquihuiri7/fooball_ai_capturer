# Dorado `n4-tiny-v1`

Arrays little-endian en orden C. `manifest.json` lleva forma, dtype, layout y la
tolerancia por salida y por ruta (`ort_fp32`, `coreml_fp16`). Lector Swift:

```swift
import Foundation

struct GoldenItem: Decodable {
    let name: String, file: String, dtype: String, shape: [Int], layout: String
}
struct Manifest: Decodable {
    let version: Int, model: String, inputs: [GoldenItem]
    let outputs: [String: [GoldenItem]]
    let tolerances: [String: [String: Double]]
}

struct Golden {
    let dir: URL
    let manifest: Manifest

    init(dir: URL) throws {
        self.dir = dir
        let datos = try Data(contentsOf: dir.appending(path: "manifest.json"))
        self.manifest = try JSONDecoder().decode(Manifest.self, from: datos)
        precondition(manifest.version == 1)
    }

    func floats(_ item: GoldenItem) throws -> [Float] {
        let datos = try Data(contentsOf: dir.appending(path: item.file))
        switch item.dtype {
        case "<f4": return datos.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        case "<f2": return datos.withUnsafeBytes {
            $0.bindMemory(to: Float16.self).map(Float.init) }
        case "|u1": return datos.map(Float.init)
        case "<i4": return datos.withUnsafeBytes {
            $0.bindMemory(to: Int32.self).map(Float.init) }
        default: fatalError("dtype \(item.dtype)")
        }
    }
}
```
