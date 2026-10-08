// El banco de modelos desde XCTest (SPK-50): el carril del Mac y el simulador.
//
// El motor vive en RigMedia (ModelBench) y es el mismo que corre en el iPhone por
// BenchRunner (`BENCH=model-bench`): en un dispositivo físico no hay «tool-hosted
// testing» para los tests de un paquete SPM, así que allí manda el carril de la
// app. Aquí se corre con los recursos del bundle de tests (BenchResources/), se
// valida el informe y se vuelca entre MODELBENCH-REPORT-BEGIN/END para capturarlo
// desde xcodebuild.
//
// Sin BenchResources/bench.json (CI, un clon limpio), el banco se salta solo. Con
// MODEL_BENCH_SPEC=<fichero> se mide otra tanda de los mismos recursos (SPK-53:
// `MODEL_BENCH_SPEC=bench-spk53.json swift test --filter ModelBenchTests`).

import Foundation
import RigMedia
import XCTest

final class ModelBenchTests: XCTestCase {
    func testBancoDeModelos() async throws {
        let fichero = ProcessInfo.processInfo.environment[ModelBench.specEnvironmentKey]
            ?? ModelBench.defaultSpec
        guard let recursos = Bundle.module.url(forResource: "BenchResources", withExtension: nil),
              FileManager.default.fileExists(
                  atPath: recursos.appendingPathComponent(fichero).path
              )
        else {
            throw XCTSkip("sin BenchResources/\(fichero): los recursos los pone SPK-51/52/53")
        }

        let inicio = Date()
        let base = BenchReport(
            name: "model-bench",
            device: Self.machine(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedEpochS: Int64(inicio.timeIntervalSince1970),
            durationS: 0,
            params: [:],
            thermal: [],
            stagesMs: [:],
            counters: [:]
        )
        var report = try await ModelBench.runAsync(
            resources: recursos, report: base, progress: nil, specName: fichero
        )
        report.durationS = Date().timeIntervalSince(inicio)

        // El dorado de ML-12 es la aceptación: ni una salida fuera de tolerancia.
        // Y en los modos paso (SPK-53), sin fugas: ni tras reiniciar ni entre dos estados.
        let sinFallos = ["/golden_violations", "/repeat_violations", "/interleave_violations"]
        for (clave, valor) in report.counters where sinFallos.contains(where: clave.hasSuffix) {
            XCTAssertEqual(valor, 0, "\(clave): \(valor) salidas fuera de tolerancia")
        }
        for (clave, _) in report.counters where clave.hasSuffix("/failed") {
            let modelo = String(clave.dropLast("/failed".count))
            XCTFail("\(modelo) falló: \(report.params["\(modelo)/error"] ?? "?")")
        }
        try write(report)
    }

    private func write(_ report: BenchReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let datos = try encoder.encode(report)

        let base = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destino = base.appendingPathComponent("model-bench-\(report.startedEpochS).json")
        try datos.write(to: destino, options: .atomic)

        let texto = String(decoding: datos, as: UTF8.self)
        let adjunto = XCTAttachment(string: texto)
        adjunto.name = "model-bench.json"
        adjunto.lifetime = .keepAlways
        add(adjunto)
        print("MODELBENCH-REPORT-BEGIN\n\(texto)\nMODELBENCH-REPORT-END")
    }

    private static func machine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
