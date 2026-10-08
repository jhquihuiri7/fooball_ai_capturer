// El banco de modelos (SPK-50): MLComputePlan, latencias y el dorado de ML-12.
//
// El motor es común a los dos carriles:
// - en el iPhone corre por BenchRunner (`BENCH=model-bench`, IOS-08), leyendo los
//   recursos de Documents/bench-resources del contenedor de la app — en un
//   dispositivo físico no hay «tool-hosted testing» para los tests de un paquete
//   SPM, así que el carril de la app ES el del banco;
// - en el Mac y el simulador lo envuelve ModelBenchTests con los recursos del
//   bundle de tests.
//
// Por cada modelo de bench.json: compila el .mlpackage (compile y load medidos por
// separado), lee del MLComputePlan la unidad y el coste por op (% del coste en el
// ANE y ops fuera), mide p50/p90/p99 de las predicciones tras calentar (con
// os_signpost, y el bucle SÍNCRONO: un await ensuciaría la medida) y comprueba el
// bundle dorado de ML-12 contra la ruta coreml_fp16 con su tolerancia. Un modelo en
// modo paso con estado (SPK-53) declara `sequence` y lo recorre SequenceBench: la
// secuencia dorada, el reinicio, dos recorridos intercalados y la latencia por paso.
//
// El banco lee `bench.json` o el fichero que diga MODEL_BENCH_SPEC (en el iPhone, por
// `devicectl … launch --environment-variables`): así se lanza una tanda sin pisar la
// otra ni recompilar. Un modelo que no carga o falla se apunta en el informe
// (`<nombre>/failed` y el error en params) y el banco sigue con el siguiente.

import CoreML
import CoreVideo
import Foundation
import os
import RigCore

// MARK: - bench.json

public struct BenchModelSpec: Decodable {
    public let name: String
    /// El directorio .mlpackage dentro de los recursos del banco.
    public let package: String
    public var predictions: Int = 1000
    public var warmup: Int = 50
    /// "cpu_and_ne" (el contrato del ADR 0020) o "cpu_only" para comparar.
    public var computeUnits: String = "cpu_and_ne"
    /// El directorio del bundle dorado de ML-12, si hay.
    public var golden: String?
    /// La función del paquete multifunción (SPK-52); nil para un paquete normal.
    public var function: String?
    /// El bundle de la secuencia dorada de un modo paso con estado (SPK-53): con él,
    /// las predicciones son pasos con el estado vivo, no entradas sueltas.
    public var sequence: String?

    enum CodingKeys: String, CodingKey {
        case name, package, predictions, warmup, golden, function, sequence
        case computeUnits = "compute_units"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        package = try c.decode(String.self, forKey: .package)
        predictions = try c.decodeIfPresent(Int.self, forKey: .predictions) ?? 1000
        warmup = try c.decodeIfPresent(Int.self, forKey: .warmup) ?? 50
        computeUnits = try c.decodeIfPresent(String.self, forKey: .computeUnits) ?? "cpu_and_ne"
        golden = try c.decodeIfPresent(String.self, forKey: .golden)
        function = try c.decodeIfPresent(String.self, forKey: .function)
        sequence = try c.decodeIfPresent(String.self, forKey: .sequence)
    }
}

public struct BenchSpec: Decodable {
    public let models: [BenchModelSpec]
}

public enum ModelBenchError: Error, CustomStringConvertible {
    case missingResources(String)
    case goldenViolated(model: String, output: String, delta: Double, atol: Double)
    case pixelBuffer(Int)

    public var description: String {
        switch self {
        case let .missingResources(ruta): return "sin recursos del banco en \(ruta)"
        case let .goldenViolated(modelo, salida, delta, atol):
            return "\(modelo)/\(salida): delta \(delta) > atol \(atol) contra el dorado"
        case let .pixelBuffer(codigo): return "CVPixelBufferCreate: \(codigo)"
        }
    }
}

// MARK: - El motor

public enum ModelBench {
    private static let signposter = OSSignposter(
        subsystem: Signposts.subsystem, category: "model-bench"
    )

    /// Los cubos del banco: los de IOS-05 más una cola larga. Un modelo que tarde
    /// segundos se MIDE, no desborda: el cubo de desborde percentila a infinito y
    /// JSON no codifica inf (fue el primer fallo real del banco en el iPhone).
    static let benchBoundsMs: [Double] =
        LatencyHistogram.defaultBoundsMs + [2000, 5000, 15000, 60000]

    /// El fichero de modelos por defecto dentro de los recursos del banco.
    public static let defaultSpec = "bench.json"

    /// La variable de entorno que elige otro fichero de modelos (SPK-53).
    public static let specEnvironmentKey = "MODEL_BENCH_SPEC"

    /// El puente síncrono para BenchRunner: bloquea mientras el trabajo async
    /// (compileModel, MLComputePlan.load) corre en otro ejecutor.
    public static func run(
        resources: URL,
        report: inout BenchReport,
        progress: BenchRunner.Progress?,
        specName: String = defaultSpec
    ) throws {
        let base = report
        var resultado: Result<BenchReport, Error> = .failure(
            ModelBenchError.missingResources(resources.path)
        )
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                resultado = .success(
                    try await runAsync(
                        resources: resources, report: base, progress: progress, specName: specName
                    )
                )
            } catch {
                resultado = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        report = try resultado.get()
    }

    public static func runAsync(
        resources: URL,
        report: BenchReport,
        progress: BenchRunner.Progress?,
        specName: String = defaultSpec
    ) async throws -> BenchReport {
        let specURL = resources.appendingPathComponent(specName)
        guard let datos = try? Data(contentsOf: specURL) else {
            throw ModelBenchError.missingResources(specURL.path)
        }
        let spec = try JSONDecoder().decode(BenchSpec.self, from: datos)
        var informe = report
        informe.params["models"] = spec.models.map(\.name).joined(separator: ",")
        informe.params["spec"] = specName

        var compilados: [String: URL] = [:]  // por nombre de entrada, para el cambio
        for (indice, modelo) in spec.models.enumerated() {
            progress?(Double(indice) / Double(max(1, spec.models.count)), modelo.name)
            do {
                compilados[modelo.name] = try await bench(
                    modelo, resources: resources, report: &informe
                )
            } catch {
                // Que un modelo no cargue (p. ej. el -14 de MLState en el ANE) ES una
                // medida: se apunta y se sigue con el resto.
                informe.counters["\(modelo.name)/failed"] = 1
                informe.params["\(modelo.name)/error"] = String(describing: error)
            }
            informe.thermal.append(thermalWord())
        }
        try benchFunctionSwitch(spec.models, compiled: compilados, report: &informe)
        return informe
    }

    /// El coste de CAMBIAR de función de un multifunción (SPK-52): predicciones
    /// alternadas entre las entradas que comparten paquete y declaran función.
    /// El sobrecoste se lee comparando `<paquete>/switch` con el p50 de cada una.
    private static func benchFunctionSwitch(
        _ models: [BenchModelSpec], compiled: [String: URL], report: inout BenchReport
    ) throws {
        let grupos = Dictionary(grouping: models.filter { $0.function != nil }, by: \.package)
        for (paquete, specs) in grupos where specs.count >= 2 {
            var cargados: [(MLModel, MLFeatureProvider)] = []
            for spec in specs {
                guard let url = compiled[spec.name] else { continue }
                let config = MLModelConfiguration()
                config.computeUnits =
                    spec.computeUnits == "cpu_only" ? .cpuOnly : .cpuAndNeuralEngine
                config.functionName = spec.function
                let modelo = try MLModel(contentsOf: url, configuration: config)
                cargados.append((modelo, try seededInputs(for: modelo)))
            }
            guard cargados.count >= 2 else { continue }
            for (modelo, entrada) in cargados {  // calienta las dos funciones
                for _ in 0..<10 { _ = try modelo.prediction(from: entrada) }
            }
            var histograma = LatencyHistogram(boundsMs: benchBoundsMs)
            for i in 0..<switchPredictions {
                let (modelo, entrada) = cargados[i % cargados.count]
                let antes = ContinuousClock.now
                _ = try modelo.prediction(from: entrada)
                histograma.record(ms: ms(antes, ContinuousClock.now))
            }
            let nombre = paquete.replacingOccurrences(of: ".mlpackage", with: "")
            report.stagesMs["\(nombre)/switch"] = BenchReport.StageSummary(histogram: histograma)
            report.counters["\(nombre)/switch_predictions"] = switchPredictions
        }
    }

    // MARK: por modelo

    /// El número de predicciones alternadas del paso de cambio de función.
    static let switchPredictions = 200

    private static func bench(
        _ spec: BenchModelSpec, resources: URL, report: inout BenchReport
    ) async throws -> URL {
        let paquete = resources.appendingPathComponent(spec.package)
        let config = MLModelConfiguration()
        config.computeUnits = spec.computeUnits == "cpu_only" ? .cpuOnly : .cpuAndNeuralEngine
        config.functionName = spec.function

        // Compilación y carga por separado: son parte del arranque de la app.
        let t0 = ContinuousClock.now
        let compilado = try await MLModel.compileModel(at: paquete)
        let t1 = ContinuousClock.now
        let modelo = try MLModel(contentsOf: compilado, configuration: config)
        let t2 = ContinuousClock.now
        // En ms exactos y como contadores: son UNA medida, no una distribución, y
        // el borde superior de un histograma de una sola muestra miente (o desborda).
        report.counters["\(spec.name)/compile_ms"] = Int(ms(t0, t1).rounded())
        report.counters["\(spec.name)/load_ms"] = Int(ms(t1, t2).rounded())

        // El plan de cómputo: unidad preferida y coste por op.
        let plan = try await MLComputePlan.load(contentsOf: compilado, configuration: config)
        let (total, fuera, costePct) = anePlan(plan)
        report.counters["\(spec.name)/ops_total"] = total
        report.counters["\(spec.name)/ops_off_ane"] = fuera
        report.counters["\(spec.name)/ane_cost_pct_x100"] = Int((costePct * 100).rounded())

        if let secuencia = spec.sequence {
            try benchSequence(
                spec, model: modelo, bundleDir: resources.appendingPathComponent(secuencia),
                report: &report
            )
            return compilado
        }

        // Latencias, en síncrono.
        let entrada = try seededInputs(for: modelo)
        let histograma = try predictLoop(
            modelo, input: entrada, warmup: spec.warmup, predictions: spec.predictions
        )
        report.stagesMs["\(spec.name)/predict"] = BenchReport.StageSummary(histogram: histograma)
        report.counters["\(spec.name)/predictions"] = spec.predictions

        if let dorado = spec.golden {
            let bundle = try GoldenBundle(dir: resources.appendingPathComponent(dorado))
            let (peor, violaciones) = try checkGolden(bundle, model: modelo)
            report.counters["\(spec.name)/golden_max_delta_x1e6"] = Int((peor * 1e6).rounded())
            report.counters["\(spec.name)/golden_violations"] = violaciones
        }
        return compilado
    }

    /// El modo paso con estado (SPK-53): la secuencia dorada, el reinicio, el
    /// intercalado y la latencia por paso, todo con el estado vivo.
    private static func benchSequence(
        _ spec: BenchModelSpec, model: MLModel, bundleDir: URL, report: inout BenchReport
    ) throws {
        let bundle = try GoldenBundle(dir: bundleDir)
        let manifiesto = try SequenceManifest(bundleDir: bundleDir)
        let r = try SequenceBench.run(
            model: model, bundle: bundle, manifest: manifiesto,
            warmup: spec.warmup, predictions: spec.predictions
        )
        report.params["\(spec.name)/state_mode"] = r.mode.rawValue
        report.stagesMs["\(spec.name)/step"] = r.latency
        report.counters["\(spec.name)/predictions"] = spec.predictions
        report.counters["\(spec.name)/sequence_steps"] = r.steps
        report.counters["\(spec.name)/golden_max_delta_x1e6"] = Int((r.goldenWorst * 1e6).rounded())
        report.counters["\(spec.name)/golden_violations"] = r.goldenViolations
        report.counters["\(spec.name)/repeat_violations"] = r.repeatViolations
        report.counters["\(spec.name)/interleave_violations"] = r.interleaveViolations
    }

    private static func predictLoop(
        _ model: MLModel, input: MLFeatureProvider, warmup: Int, predictions: Int
    ) throws -> LatencyHistogram {
        for _ in 0..<warmup {
            _ = try model.prediction(from: input)
        }
        var histograma = LatencyHistogram(boundsMs: benchBoundsMs)
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
    static func seededInputs(for model: MLModel) throws -> MLFeatureProvider {
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
        let codigo = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        guard let listo = buffer else {
            throw ModelBenchError.pixelBuffer(Int(codigo))
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
        let codigo = CVPixelBufferCreate(
            nil, ancho, alto, kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        guard let listo = buffer else {
            throw ModelBenchError.pixelBuffer(Int(codigo))
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
    /// tolerancia. Devuelve el peor delta y cuántas salidas se pasaron.
    static func checkGolden(
        _ bundle: GoldenBundle, model: MLModel
    ) throws -> (worst: Double, violations: Int) {
        var peor = 0.0
        var violaciones = 0
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
                    violaciones += 1
                    continue
                }
                let esperado = try bundle.floats(item)
                let tolerancia = try bundle.tolerance(outputName: item.name, route: "coreml_fp16")
                let delta = maxDelta(valor, esperado)
                if delta > tolerancia {
                    violaciones += 1
                }
                peor = max(peor, delta)
            }
        }
        return (peor, violaciones)
    }

    private static func maxDelta(_ visto: MLMultiArray, _ esperado: [Float]) -> Double {
        var delta = 0.0
        if visto.dataType == .float32 {
            visto.withUnsafeBufferPointer(ofType: Float.self) { puntero in
                for i in 0..<min(puntero.count, esperado.count) {
                    delta = max(delta, Double(abs(puntero[i] - esperado[i])))
                }
            }
        } else {
            for i in 0..<min(visto.count, esperado.count) {
                delta = max(delta, abs(visto[i].doubleValue - Double(esperado[i])))
            }
        }
        return delta
    }

    // MARK: utilidades

    private static func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = b - a
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
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
