// El lector del bundle dorado, contra datos sintéticos (SPK-50). Corre en el Mac.

import Foundation
import RigMedia
import XCTest

final class GoldenBundleTests: XCTestCase {
    private func makeBundle(tolerances: String = """
        {"logits_000": {"coreml_fp16": 0.02, "ort_fp32": 0.001}}
        """) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("entradas"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("salidas/coreml_fp16"), withIntermediateDirectories: true
        )
        let manifiesto = """
        {
          "version": 1,
          "model": "demo",
          "model_version": "v1",
          "inputs": [
            {"name": "image_000", "file": "entradas/image_000.bin", "dtype": "|u1",
             "shape": [2, 2, 4], "layout": "BGRA8"}
          ],
          "outputs": {
            "coreml_fp16": [
              {"name": "logits_000", "file": "salidas/coreml_fp16/logits_000.bin",
               "dtype": "<f2", "shape": [1, 2], "layout": "NC"}
            ]
          },
          "tolerances": \(tolerances)
        }
        """
        try manifiesto.write(
            to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
        )
        try Data((0..<16).map { UInt8($0) }).write(
            to: dir.appendingPathComponent("entradas/image_000.bin")
        )
        // Dos float16 little-endian: 1.0 (0x3C00) y -2.0 (0xC000).
        try Data([0x00, 0x3C, 0x00, 0xC0]).write(
            to: dir.appendingPathComponent("salidas/coreml_fp16/logits_000.bin")
        )
        return dir
    }

    func testLeeManifestArraysYTolerancias() throws {
        let bundle = try GoldenBundle(dir: try makeBundle())

        XCTAssertEqual(bundle.sampleIndices, [0])
        XCTAssertEqual(bundle.inputBases(sample: 0), ["image"])
        XCTAssertEqual(bundle.outputBases(route: "coreml_fp16", sample: 0), ["logits"])

        let entrada = bundle.input(base: "image", sample: 0)!
        XCTAssertEqual(try bundle.floats(entrada), (0..<16).map(Float.init))

        let salida = bundle.output(route: "coreml_fp16", base: "logits", sample: 0)!
        XCTAssertEqual(try bundle.floats(salida), [1.0, -2.0])  // <f2 little-endian

        XCTAssertEqual(
            try bundle.tolerance(outputName: "logits_000", route: "coreml_fp16"), 0.02
        )
    }

    func testLaToleranciaQueFaltaEsUnBundleRoto() throws {
        let bundle = try GoldenBundle(dir: try makeBundle(tolerances: "{}"))
        XCTAssertThrowsError(
            try bundle.tolerance(outputName: "logits_000", route: "coreml_fp16")
        )
    }

    func testUnTamanoQueNoCuadraSeRechaza() throws {
        let dir = try makeBundle()
        try Data([0x00]).write(to: dir.appendingPathComponent("entradas/image_000.bin"))
        let bundle = try GoldenBundle(dir: dir)
        XCTAssertThrowsError(try bundle.floats(bundle.input(base: "image", sample: 0)!))
    }
}
