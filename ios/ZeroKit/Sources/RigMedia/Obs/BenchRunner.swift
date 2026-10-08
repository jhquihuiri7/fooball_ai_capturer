// El corredor de bancos (IOS-08): corre un banco por nombre y deja el informe JSON.
//
// Es la mitad nativa de la prueba de una sola acción: la app arranca con
// `--dart-define=BENCH=<nombre>`, esto corre sin tocar la pantalla y escribe
// Documents/bench/<nombre>-<epoch>.json; `tools/bench_pull.sh` lo baja al Mac y
// `tools/bench_summary.dart` lo resume. Los bancos de verdad (ANE, enlace, térmica)
// se registran aquí según llegan sus tarjetas; `noop` existe para probar la tubería.

import Foundation
import os
import RigCore

public enum BenchError: Error, CustomStringConvertible {
    case unknownBench(String)
    public var description: String {
        switch self {
        case let .unknownBench(nombre): return "banco desconocido: \(nombre)"
        }
    }
}

/// El informe de un banco. Codable y estable: lo lee `bench_summary.dart` en el Mac o
/// en Windows, así que las claves no cambian sin cambiar también esa herramienta.
public struct BenchReport: Codable, Equatable {
    public struct StageSummary: Codable, Equatable {
        public var p50Ms: Double
        public var p90Ms: Double
        public var p99Ms: Double

        public init(histogram: LatencyHistogram) {
            p50Ms = histogram.p50Ms
            p90Ms = histogram.p90Ms
            p99Ms = histogram.p99Ms
        }

        /// Percentiles ya calculados, para los bancos que miden por debajo del ms y
        /// guardan las muestras en crudo (director-bench).
        public init(p50Ms: Double, p90Ms: Double, p99Ms: Double) {
            self.p50Ms = p50Ms
            self.p90Ms = p90Ms
            self.p99Ms = p99Ms
        }

        enum CodingKeys: String, CodingKey {
            case p50Ms = "p50_ms"
            case p90Ms = "p90_ms"
            case p99Ms = "p99_ms"
        }
    }

    public var name: String
    /// `utsname.machine`: «iPhone18,1», no el nombre comercial. Es lo que distingue un
    /// 17 base de un Pro en los informes.
    public var device: String
    public var systemVersion: String
    public var startedEpochS: Int64
    public var durationS: Double
    public var params: [String: String]
    /// La línea térmica: el estado al empezar y al acabar (los bancos largos muestrean
    /// por su cuenta y añaden entradas).
    public var thermal: [String]
    public var stagesMs: [String: StageSummary]
    public var counters: [String: Int]

    /// Público adrede: ModelBenchTests (SPK-50) construye el informe desde el target
    /// de tests, y el memberwise de serie es interno.
    public init(
        name: String,
        device: String,
        systemVersion: String,
        startedEpochS: Int64,
        durationS: Double,
        params: [String: String],
        thermal: [String],
        stagesMs: [String: StageSummary],
        counters: [String: Int]
    ) {
        self.name = name
        self.device = device
        self.systemVersion = systemVersion
        self.startedEpochS = startedEpochS
        self.durationS = durationS
        self.params = params
        self.thermal = thermal
        self.stagesMs = stagesMs
        self.counters = counters
    }

    enum CodingKeys: String, CodingKey {
        case name, device, params, thermal, counters
        case systemVersion = "system_version"
        case startedEpochS = "started_epoch_s"
        case durationS = "duration_s"
        case stagesMs = "stages_ms"
    }
}

public final class BenchRunner {
    public typealias Progress = (Double, String) -> Void

    /// Un banco rellena el informe (histogramas, contadores, térmica intermedia).
    public typealias Bench = (inout BenchReport, Progress?) throws -> Void

    /// El registro de bancos. `noop` prueba la tubería entera sin hacer nada;
    /// `pipeline-noop` (IOS-09) mide el blit del anillo con fotogramas sintéticos;
    /// `vt-concurrency` (SPK-03) carga cámara, HEVC, H.264 y decodificación a la vez;
    /// `model-bench` (SPK-50) mide .mlpackage con sus recursos en
    /// Documents/bench-resources (se suben con `devicectl device copy to`);
    /// `director-bench` (IOS-37) mide el bucle del director por fotograma,
    /// `decoder-bench` (IOS-23), el decodificador de jugadores sin el modelo, y
    /// `metal-bench` (IOS-40/41/21), el tiempo de GPU de los kernels.
    private static let benches: [String: Bench] = [
        "noop": { report, _ in
            report.counters["noop"] = 1
        },
        "pipeline-noop": { report, progress in
            try PipelineBench.run(report: &report, progress: progress)
        },
        "vt-concurrency": { report, progress in
            try VtConcurrencyBench.run(report: &report, progress: progress)
        },
        "metal-bench": { report, progress in
            try MetalBench.run(report: &report, progress: progress)
        },
        "director-bench": { report, progress in
            try DirectorBench.run(report: &report, progress: progress)
        },
        "decoder-bench": { report, progress in
            try DecoderBench.run(report: &report, progress: progress)
        },
        "model-bench": { report, progress in
            let documentos = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            try ModelBench.run(
                resources: documentos.appendingPathComponent("bench-resources"),
                report: &report,
                progress: progress
            )
        },
    ]

    private static let log = Logger(subsystem: Signposts.subsystem, category: "bench")

    /// Corre el banco y devuelve la URL del informe escrito.
    public static func run(
        name: String,
        paramsJson: String,
        directory: URL? = nil,
        progress: Progress? = nil
    ) throws -> URL {
        guard let bench = benches[name] else {
            throw BenchError.unknownBench(name)
        }
        let inicio = Date()
        var report = BenchReport(
            name: name,
            device: Self.machine(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedEpochS: Int64(inicio.timeIntervalSince1970),
            durationS: 0,
            params: Self.params(from: paramsJson),
            thermal: [Self.thermalWord()],
            stagesMs: [:],
            counters: [:]
        )
        progress?(0, "arrancando \(name)")
        try bench(&report, progress)
        report.thermal.append(Self.thermalWord())
        report.durationS = Date().timeIntervalSince(inicio)
        progress?(1, "escribiendo el informe")

        let base = try directory ?? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destino = base.appendingPathComponent("\(name)-\(report.startedEpochS).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: destino, options: .atomic)
        log.info("banco \(name) escrito en \(destino.lastPathComponent)")
        return destino
    }

    public static func machine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func params(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let crudo = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return crudo.mapValues { "\($0)" }
    }

    private static func thermalWord() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "critical"
        }
    }
}
