// El banco del modo paso con estado (SPK-53), contra el gemelo diminuto de N4. Corre en
// el Mac, en la CPU (MLState y la E/S explícita funcionan igual ahí).
//
// Los fixtures los genera el repo de entrenamiento con pesos sembrados:
//
//   uv run python tools/export_coreml.py --spec configs/export/n4-tiny-mlstate.yaml \
//       --builder ftrain.events.spotter_export:build_tiny_stateful --out runs/spk53/fixtures --keep-package
//   uv run python tools/export_coreml.py --spec configs/export/n4-tiny-explicit.yaml \
//       --builder ftrain.events.spotter_export:build_tiny_explicit --out runs/spk53/fixtures --keep-package
//   uv run python tools/golden_sequence.py --spec configs/export/n4-tiny-mlstate.yaml \
//       --builder ftrain.events.spotter_export:build_tiny --name n4-tiny --version v1 \
//       --steps 12 --out runs/spk53/fixtures/golden
//
// y se copian aquí: n4-tiny-mlstate.mlpackage, n4-tiny-explicit.mlpackage y n4-tiny-v1/.

import CoreML
import Foundation
import RigCore
@testable import RigMedia
import XCTest

final class SequenceBenchTests: XCTestCase {
    private var fixtures: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    private func model(_ nombre: String) throws -> MLModel {
        let compilado = try MLModel.compileModel(
            at: fixtures.appendingPathComponent("\(nombre).mlpackage")
        )
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        return try MLModel(contentsOf: compilado, configuration: config)
    }

    private func golden() throws -> (GoldenBundle, SequenceManifest) {
        let dir = fixtures.appendingPathComponent("n4-tiny-v1")
        return (try GoldenBundle(dir: dir), try SequenceManifest(bundleDir: dir))
    }

    func testElManifiestoDeLaSecuencia() throws {
        let (bundle, manifiesto) = try golden()
        XCTAssertEqual(manifiesto.steps, 12)
        XCTAssertEqual(manifiesto.frameInput, "frame")
        XCTAssertEqual(manifiesto.outputs, ["logits", "h"])
        XCTAssertEqual(bundle.sampleIndices, Array(0..<12))
        XCTAssertEqual(try SequenceBench.frames(bundle, manifest: manifiesto).count, 12)
    }

    func testMLStateRecorreLaSecuenciaSinFugas() throws {
        let (bundle, manifiesto) = try golden()
        let r = try SequenceBench.run(
            model: try model("n4-tiny-mlstate"), bundle: bundle, manifest: manifiesto,
            warmup: 2, predictions: 20
        )
        XCTAssertEqual(r.mode, .mlState)
        XCTAssertEqual(r.goldenViolations, 0, "peor delta \(r.goldenWorst)")
        XCTAssertEqual(r.repeatViolations, 0)
        XCTAssertEqual(r.interleaveViolations, 0)
        XCTAssertGreaterThan(r.latency.p50Ms, 0)
    }

    func testEstadoExplicitoRecorreLaSecuenciaSinFugas() throws {
        let (bundle, manifiesto) = try golden()
        let r = try SequenceBench.run(
            model: try model("n4-tiny-explicit"), bundle: bundle, manifest: manifiesto,
            warmup: 2, predictions: 20
        )
        XCTAssertEqual(r.mode, .explicit)
        XCTAssertEqual(r.goldenViolations, 0, "peor delta \(r.goldenWorst)")
        XCTAssertEqual(r.repeatViolations, 0)
        XCTAssertEqual(r.interleaveViolations, 0)
    }

    /// El contraejemplo: sin reiniciar, la segunda pasada arranca con el estado de la
    /// primera y el dorado lo ve. Si esto diera 0, el banco no detectaría una fuga.
    func testSinReiniciarElDoradoVeLaFuga() throws {
        let (bundle, manifiesto) = try golden()
        let fotogramas = try SequenceBench.frames(bundle, manifest: manifiesto)
        for nombre in ["n4-tiny-mlstate", "n4-tiny-explicit"] {
            let stepper = try SequenceStepper(model: try model(nombre), frameInput: "frame")
            let limpia = try SequenceBench.runSequence(
                stepper, frames: fotogramas, bundle: bundle, manifest: manifiesto
            )
            XCTAssertEqual(limpia.violations, 0, nombre)
            let sucia = try SequenceBench.runSequence(
                stepper, frames: fotogramas, bundle: bundle, manifest: manifiesto, reset: false
            )
            XCTAssertGreaterThan(sucia.violations, 0, nombre)
        }
    }

    func testLasDosVariantesDanLoMismo() throws {
        let (bundle, manifiesto) = try golden()
        let fotogramas = try SequenceBench.frames(bundle, manifest: manifiesto)
        let a = try SequenceStepper(model: try model("n4-tiny-mlstate"), frameInput: "frame")
        let b = try SequenceStepper(model: try model("n4-tiny-explicit"), frameInput: "frame")
        for fotograma in fotogramas {
            try a.step(fotograma)
            try b.step(fotograma)
            for nombre in ["logits", "h"] {
                let (va, vb) = (try a.values(nombre), try b.values(nombre))
                XCTAssertEqual(va.count, vb.count)
                for i in 0..<va.count {
                    XCTAssertEqual(va[i], vb[i], accuracy: 1e-3, nombre)
                }
            }
        }
    }

    func testUnModeloSinEstadoNoEsUnModoPaso() throws {
        XCTAssertThrowsError(
            try SequenceStepper(model: try model("tiny-detr"), frameInput: "image")
        )
    }

    func testLosFloatsRespetanLosStridesDeUnIOSurface() throws {
        let array = try SequenceStepper.surfaceArray(shape: [1, 2, 3, 5])
        array.withUnsafeMutableBytes { crudo, pasos in
            let destino = crudo.bindMemory(to: Float16.self)
            for c in 0..<2 {
                for y in 0..<3 {
                    for x in 0..<5 {
                        let i = c * pasos[1] + y * pasos[2] + x
                        destino[i] = Float16(Float(c * 100 + y * 10 + x))
                    }
                }
            }
        }
        let valores = SequenceStepper.floats(array)
        XCTAssertEqual(valores.count, 30)
        XCTAssertEqual(valores[0], 0)
        XCTAssertEqual(valores[7], 12)  // c0 y1 x2
        XCTAssertEqual(valores[29], 124)  // c1 y2 x4
    }

    /// El banco entero por bench.json, como en el iPhone: los contadores del informe.
    func testElBancoDeModelosMideElModoPaso() async throws {
        let recursos = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recursos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recursos) }
        for nombre in ["n4-tiny-mlstate.mlpackage", "n4-tiny-explicit.mlpackage", "n4-tiny-v1"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(nombre),
                to: recursos.appendingPathComponent(nombre)
            )
        }
        let spec = """
        {"models": [
          {"name": "tiny-mlstate", "package": "n4-tiny-mlstate.mlpackage",
           "sequence": "n4-tiny-v1", "predictions": 20, "warmup": 2, "compute_units": "cpu_only"},
          {"name": "tiny-explicit", "package": "n4-tiny-explicit.mlpackage",
           "sequence": "n4-tiny-v1", "predictions": 20, "warmup": 2, "compute_units": "cpu_only"},
          {"name": "no-existe", "package": "no-existe.mlpackage"}
        ]}
        """
        try spec.write(
            to: recursos.appendingPathComponent("bench-seq.json"), atomically: true, encoding: .utf8
        )
        let base = BenchReport(
            name: "model-bench", device: "mac", systemVersion: "", startedEpochS: 0,
            durationS: 0, params: [:], thermal: [], stagesMs: [:], counters: [:]
        )
        let informe = try await ModelBench.runAsync(
            resources: recursos, report: base, progress: nil, specName: "bench-seq.json"
        )
        XCTAssertEqual(informe.params["spec"], "bench-seq.json")
        for (nombre, modo) in [("tiny-mlstate", "mlstate"), ("tiny-explicit", "explicit")] {
            XCTAssertEqual(informe.params["\(nombre)/state_mode"], modo)
            XCTAssertEqual(informe.counters["\(nombre)/sequence_steps"], 12)
            XCTAssertEqual(informe.counters["\(nombre)/golden_violations"], 0)
            XCTAssertEqual(informe.counters["\(nombre)/repeat_violations"], 0)
            XCTAssertEqual(informe.counters["\(nombre)/interleave_violations"], 0)
            XCTAssertNotNil(informe.stagesMs["\(nombre)/step"])
            XCTAssertNotNil(informe.counters["\(nombre)/ane_cost_pct_x100"])
            XCTAssertNil(informe.counters["\(nombre)/failed"])
        }
        // Un modelo que no carga se apunta y el banco sigue.
        XCTAssertEqual(informe.counters["no-existe/failed"], 1)
        XCTAssertNotNil(informe.params["no-existe/error"])
    }
}
