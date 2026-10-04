// El banco de modelos en el iPhone (SPK-50): MLComputePlan, latencias y dorados.
//
// Lee BenchResources/bench.json (modelos, computeUnits, número de predicciones)
// y, por cada modelo: compila el .mlpackage, lee del MLComputePlan la unidad y
// el coste por op (% del coste en el ANE y ops fuera), mide p50/p90/p99 de las
// predicciones tras calentar (con os_signpost) y los tiempos de carga y
// compilación, y comprueba el bundle dorado de ML-12 con su tolerancia.
//
// El informe sigue el esquema de BenchRunner (IOS-08): se escribe en
// Documents/bench del runner, va como XCTAttachment y se vuelca entero al log
// entre MODELBENCH-REPORT-BEGIN/END para capturarlo desde xcodebuild.
//
// Sin BenchResources/bench.json (el Mac, CI), el banco se salta solo: los
// recursos los pone quien lanza el banco (SPK-51/SPK-52), no el repo.

import CoreML
import CoreVideo
import Foundation
import os
import RigCore
import RigMedia
import XCTest

// MARK: - bench.json

struct BenchModelSpec: Decodable {
    let name: String
    /// El directorio .mlpackage dentro de BenchResources.
    let package: String
    var predictions: Int = 1000
    var warmup: Int = 50
    /// "cpu_and_ne" (el contrato del ADR 0020) o "cpu_only" para comparar.
    var computeUnits: String = "cpu_and_ne"
    /// El directorio del bundle dorado de ML-12 dentro de BenchResources, si hay.
    var golden: String?

    enum CodingKeys: String, CodingKey {
        case name, package, predictions, warmup, golden
        case computeUnits = "compute_units"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        package = try c.decode(String.self, forKey: .package)
        predictions = try c.decodeIfPresent(Int.self, forKey: .predictions) ?? 1000
        warmup = try c.decodeIfPresent(Int.self, forKey: .warmup) ?? 50
        computeUnits = try c.decodeIfPresent(String.self, forKey: .computeUnits) ?? "cpu_and_ne"
        golden = try c.decodeIfPresent(String.self, forKey: .golden)
    }
}

struct BenchSpec: Decodable {
    let models: [BenchModelSpec]
}

// MARK: - El banco

final class ModelBenchTests: XCTestCase {
    private static let signposter = OSSignposter(
        subsystem: Signposts.subsystem, category: "model-bench"
    )

    func testBancoDeModelos() async throws {
        guard let recursos = Bundle.module.url(forResource: "BenchResources", withExtension: nil),
              let specData = try? Data(contentsOf: recursos.appendingPathComponent("bench.json"))
        else {
            throw XCTSkip("sin BenchResources/bench.json: el banco lo lanza SPK-51/52")
        }
        let spec = try JSONDecoder().decode(BenchSpec.self, from: specData)

        let inicio = Date()
        var report = BenchReport(
            name: "model-bench",
            device: Self.machine(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedEpochS: Int64(inicio.timeIntervalSince1970),
            durationS: 0,
            params: ["models": spec.models.map(\.name).joined(separator: ",")],
            thermal: [Self.thermalWord()],
            stagesMs: [:],
            counters: [:]
        )

        for modelo in spec.models {
            try await bench(modelo, resources: recursos, report: &report)
            report.thermal.append(Self.thermalWord())
        }

        report.durationS = Date().timeIntervalSince(inicio)
        try write(report)
    }

    // MARK: por modelo

    private func bench(
        _ spec: BenchModelSpec, resources: URL, report: inout BenchReport
    ) async throws {
        let paquete = resources.appendingPathComponent(spec.package)
        let config = MLModelConfiguration()
        config.computeUnits = spec.computeUnits == "cpu_only" ? .cpuOnly : .cpuAndNeuralEngine

        // Compilación y carga, medidas por separado: son parte del arranque de la app.
        let t0 = ContinuousClock.now
        let compilado = try await MLModel.compileModel(at: paquete)
        let t1 = ContinuousClock.now
        let modelo = try MLModel(contentsOf: compilado, configuration: config)
        let t2 = ContinuousClock.now
        report.stagesMs["\(spec.name)/compile"] = Self.single(ms: Self.ms(t0, t1))
        report.stagesMs["\(spec.name)/load"] = Self.single(ms: Self.ms(t1, t2))

        // El plan de cómputo: unidad preferida y coste por op.
        let plan = try await MLComputePlan.load(contentsOf: compilado, configuration: config)
        let (total, fuera, costePct) = Self.anePlan(plan)
        report.counters["\(spec.name)/ops_total"] = total
        report.counters["\(spec.name)/ops_off_ane"] = fuera
        report.counters["\(spec.name)/ane_cost_pct_x100"] = Int((costePct * 100).rounded())

        // Latencias: calentar y medir, con os_signpost por predicción. El bucle va
        // en una función SÍNCRONA: en contexto async, Swift resolvería prediction a
        // su sobrecarga async y el await ensuciaría la medida.
        let entrada = try Self.seededInputs(for: modelo)
        let histograma = try Self.predictLoop(
            modelo, input: entrada, warmup: spec.warmup, predictions: spec.predictions
        )
        report.stagesMs["\(spec.name)/predict"] = BenchReport.StageSummary(histogram: histograma)
        report.counters["\(spec.name)/predictions"] = spec.predictions

        if let dorado = spec.golden {
            let bundle = try GoldenBundle(dir: resources.appendingPathComponent(dorado))
            let peor = try Self.checkGolden(bundle, model: modelo, name: spec.name)
            report.counters["\(spec.name)/golden_max_delta_x1e6"] = Int((peor * 1e6).rounded())
        }
    }

    private static func predictLoop(
        _ model: MLModel, input: MLFeatureProvider, warmup: Int, predictions: Int
    ) throws -> LatencyHistogram {
        for _ in 0..<warmup {
            _ = try model.prediction(from: input)
        }
        var histograma = LatencyHistogram()
        for _ in 0..<predictions {
            let estado = signposter.beginInterval("predict")
            let antes = ContinuousClock.now
            _ = try model.prediction(from: input)
            histograma.record(ms: ms(antes, ContinuousClock.now))
            signposter.endInterval("predict", estado)
        }
        return histograma
    }

    // MARK: MLComputePlan

    private static func anePlan(_ plan: MLComputePlan) -> (total: Int, offAne: Int, anePct: Double) {
        guard case let .program(programa) = plan.modelStructure else { return (0, 0, 0) }
        var total = 0
        var fuera = 0
        var costeTotal = 0.0
        var costeAne = 0.0
        for funcion in programa.functions.values {
            for operacion in funcion.block.operations {
                total += 1
                let coste = plan.estimatedCost(of: operacion)?.weight ?? 0
                costeTotal += coste
                var enAne = false
                if let uso = plan.deviceUsage(for: operacion),
                   case .neuralEngine = uso.preferred {
                    enAne = true
                }
                if enAne {
                    costeAne += coste
                } else {
                    fuera += 1
                }
            }
        }
        return (total, fuera, costeTotal > 0 ? costeAne / costeTotal * 100 : 0)
    }

    // MARK: entradas

    /// Entradas con semilla fija: imagen BGRA de ruido o MLMultiArray de ruido.
    private static func seededInputs(for model: MLModel) throws -> MLFeatureProvider {
        var rng = SplitMix64(seed: 0)
        var features: [String: MLFeatureValue] = [:]
        for (nombre, descripcion) in model.modelDescription.inputDescriptionsByName {
            if let imagen = descripcion.imageConstraint {
                features[nombre] = MLFeatureValue(
                    pixelBuffer: try noisePixelBuffer(
                        width: imagen.pixelsWide, height: imagen.pixelsHigh, rng: &rng
                    )
                )
            } else if let arreglo = descripcion.multiArrayConstraint {
                let multi = try MLMultiArray(shape: arreglo.shape, dataType: .float32)
                for i in 0..<multi.count {
                    multi[i] = NSNumber(value: Float(rng.next() % 1000) / 1000.0)
                }
                features[nombre] = MLFeatureValue(multiArray: multi)
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    private static func noisePixelBuffer(
        width: Int, height: Int, rng: inout SplitMix64
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let listo = buffer else {
            throw NSError(domain: "model-bench", code: 1, userInfo: nil)
        }
        CVPixelBufferLockBaseAddress(listo, [])
        defer { CVPixelBufferUnlockBaseAddress(listo, []) }
        let base = CVPixelBufferGetBaseAddress(listo)!
        let porFila = CVPixelBufferGetBytesPerRow(listo)
        for fila in 0..<height {
            let destino = base.advanced(by: fila * porFila).assumingMemoryBound(to: UInt8.self)
            for byte in 0..<(width * 4) {
                destino[byte] = UInt8(truncatingIfNeeded: rng.next())
            }
        }
        return listo
    }

    /// BGRA8 del bundle (H, W, 4) a CVPixelBuffer, respetando bytesPerRow.
    private static func pixelBuffer(bgra datos: Data, shape: [Int]) throws -> CVPixelBuffer {
        let alto = shape[0]
        let ancho = shape[1]
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, ancho, alto, kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let listo = buffer else {
            throw NSError(domain: "model-bench", code: 2, userInfo: nil)
        }
        CVPixelBufferLockBaseAddress(listo, [])
        defer { CVPixelBufferUnlockBaseAddress(listo, []) }
        let base = CVPixelBufferGetBaseAddress(listo)!
        let porFila = CVPixelBufferGetBytesPerRow(listo)
        datos.withUnsafeBytes { (crudo: UnsafeRawBufferPointer) in
            for fila in 0..<alto {
                memcpy(
                    base.advanced(by: fila * porFila),
                    crudo.baseAddress!.advanced(by: fila * ancho * 4),
                    ancho * 4
                )
            }
        }
        return listo
    }

    // MARK: el dorado de ML-12

    /// Predice las muestras del bundle y compara contra la ruta coreml_fp16 con su
    /// tolerancia. Devuelve el peor delta. Falla el test si alguna salida se pasa.
    private static func checkGolden(
        _ bundle: GoldenBundle, model: MLModel, name: String
    ) throws -> Double {
        var peor = 0.0
        for muestra in bundle.sampleIndices {
            var features: [String: MLFeatureValue] = [:]
            for base in bundle.inputBases(sample: muestra) {
                guard let item = bundle.input(base: base, sample: muestra) else { continue }
                if item.layout == "BGRA8" {
                    features[base] = MLFeatureValue(
                        pixelBuffer: try pixelBuffer(bgra: try bundle.data(item), shape: item.shape)
                    )
                } else {
                    let multi = try MLMultiArray(
                        shape: item.shape.map { NSNumber(value: $0) }, dataType: .float32
                    )
                    for (i, valor) in (try bundle.floats(item)).enumerated() {
                        multi[i] = NSNumber(value: valor)
                    }
                    features[base] = MLFeatureValue(multiArray: multi)
                }
            }
            let salida = try model.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: features)
            )
            for base in bundle.outputBases(route: "coreml_fp16", sample: muestra) {
                guard let item = bundle.output(route: "coreml_fp16", base: base, sample: muestra),
                      let valor = salida.featureValue(for: base)?.multiArrayValue
                else {
                    XCTFail("\(name): el modelo no emite \(base)")
                    continue
                }
                let esperado = try bundle.floats(item)
                let tolerancia = try bundle.tolerance(outputName: item.name, route: "coreml_fp16")
                var delta = 0.0
                valor.withUnsafeBufferPointer(ofType: Float.self) { visto in
                    for i in 0..<min(visto.count, esperado.count) {
                        delta = max(delta, Double(abs(visto[i] - esperado[i])))
                    }
                }
                XCTAssertLessThanOrEqual(
                    delta, tolerancia,
                    "\(name)/\(base) muestra \(muestra): delta \(delta) > atol \(tolerancia)"
                )
                peor = max(peor, delta)
            }
        }
        return peor
    }

    // MARK: el informe

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
        // El volcado al log es lo que captura xcodebuild sin ir a buscar el contenedor.
        print("MODELBENCH-REPORT-BEGIN\n\(texto)\nMODELBENCH-REPORT-END")
    }

    // MARK: utilidades

    private static func single(ms: Double) -> BenchReport.StageSummary {
        var h = LatencyHistogram()
        h.record(ms: ms)
        return BenchReport.StageSummary(histogram: h)
    }

    private static func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = b - a
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }

    private static func machine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
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

/// Un RNG mínimo y determinista: las entradas del banco son siempre las mismas.
struct SplitMix64 {
    private var estado: UInt64
    init(seed: UInt64) { estado = seed }
    mutating func next() -> UInt64 {
        estado &+= 0x9E37_79B9_7F4A_7C15
        var z = estado
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
