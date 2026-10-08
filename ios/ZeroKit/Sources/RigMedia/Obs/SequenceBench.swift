// La secuencia dorada de un modelo en modo paso con estado (SPK-53).
//
// El bundle es el de ML-12 (GoldenBundle) más `sequence.json`, y lo genera
// tools/golden_sequence.py del repo de entrenamiento: los fotogramas `frame_NNN` en
// uint8 planar y, por paso, `logits_NNN` y `h_NNN` (el estado de la GRU) por la ruta
// torch_fp32, con su tolerancia fp16. Los pasos van EN ORDEN, con un solo estado que
// arranca en cero.
//
// Dos maneras de llevar el estado, que es lo que SPK-53 compara:
// - MLState (iOS 18): el modelo declara sus estados; `makeState()` da uno a cero y cada
//   predicción lo lee y lo escribe. Reiniciar es pedir otro.
// - Explícita: cada estado X entra como la entrada X y sale como X_out. Se recicla en
//   doble búfer, dos juegos de MLMultiArray fp16 sobre IOSurface: `outputBackings`
//   escribe la salida del paso k en el juego que el paso k+1 lee como entrada, sin
//   copiar nada ni reservar memoria dentro del bucle.
//
// Por modelo se comprueba: la secuencia contra el dorado, la misma otra vez tras
// reiniciar (el reinicio vuelve de verdad a cero) y dos recorridos intercalados sobre
// el mismo MLModel con un desfase (ninguno ve el estado del otro). Y se mide la
// latencia por paso, con el estado vivo.

import CoreML
import CoreVideo
import Foundation
import os
import RigCore

// MARK: - sequence.json

public struct SequenceManifest: Decodable {
    public let version: Int
    public let steps: Int
    /// La entrada del fotograma; las demás entradas del modelo son estado.
    public let frameInput: String
    /// Del byte al valor que ve el modelo: Float16(Float(byte) * Float(frameScale)).
    public let frameScale: Double
    /// Las salidas que se comparan por paso (`logits`, `h`).
    public let outputs: [String]
    public let referenceRoute: String
    public let toleranceRoute: String
    /// El sufijo de la salida que devuelve un estado explícito (`h` → `h_out`).
    public let explicitSuffix: String

    enum CodingKeys: String, CodingKey {
        case version, steps, outputs
        case frameInput = "frame_input"
        case frameScale = "frame_scale"
        case referenceRoute = "reference_route"
        case toleranceRoute = "tolerance_route"
        case explicitSuffix = "explicit_suffix"
    }

    public static let supportedVersion = 1

    public init(bundleDir: URL) throws {
        let datos = try Data(contentsOf: bundleDir.appendingPathComponent("sequence.json"))
        self = try JSONDecoder().decode(SequenceManifest.self, from: datos)
        guard version == Self.supportedVersion else {
            throw SequenceBenchError.badVersion(version)
        }
    }
}

public enum SequenceBenchError: Error, CustomStringConvertible {
    case badVersion(Int)
    case notStateful(String)
    case missingFrame(Int)
    case missingValue(String)
    case pixelBuffer(Int32)

    public var description: String {
        switch self {
        case let .badVersion(v): return "sequence.json versión \(v): este lector lee la 1"
        case let .notStateful(motivo): return "el modelo no es un modo paso con estado: \(motivo)"
        case let .missingFrame(paso): return "falta el fotograma del paso \(paso)"
        case let .missingValue(nombre): return "ni salida, ni \(nombre)_out, ni estado \(nombre)"
        case let .pixelBuffer(codigo): return "CVPixelBufferCreate: \(codigo)"
        }
    }
}

public enum StateMode: String {
    case mlState = "mlstate"
    case explicit
}

// MARK: - El recorrido con estado

/// Las entradas de un paso, mutables: el fotograma cambia y el estado no se reserva.
private final class StepInputs: NSObject, MLFeatureProvider {
    var values: [String: MLFeatureValue]
    init(_ values: [String: MLFeatureValue]) { self.values = values }
    var featureNames: Set<String> { Set(values.keys) }
    func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}

/// Un recorrido con su propio estado sobre un MLModel. Dos steppers del mismo modelo no
/// comparten nada: es lo que comprueba el recorrido intercalado.
public final class SequenceStepper {
    public let mode: StateMode
    private let model: MLModel
    private let frameName: String
    private let suffix: String
    private var state: MLState?
    /// Explícito: los dos juegos del doble búfer, por nombre de la entrada de estado.
    private var sets: [[String: MLMultiArray]] = []
    private var inputs: [StepInputs] = []
    private var options: [MLPredictionOptions] = []
    private var parity = 0
    private var last: MLFeatureProvider?

    public init(model: MLModel, frameInput: String, explicitSuffix: String = "_out") throws {
        self.model = model
        frameName = frameInput
        suffix = explicitSuffix
        let descripcion = model.modelDescription
        if !descripcion.stateDescriptionsByName.isEmpty {
            mode = .mlState
            inputs = [StepInputs([:])]
            options = [MLPredictionOptions()]
        } else {
            let estados = descripcion.inputDescriptionsByName.filter { nombre, _ in
                nombre != frameInput
                    && descripcion.outputDescriptionsByName[nombre + explicitSuffix] != nil
            }
            guard !estados.isEmpty else {
                throw SequenceBenchError.notStateful(
                    "ni estados MLState ni entradas X con su salida X\(explicitSuffix)"
                )
            }
            mode = .explicit
            for _ in 0..<2 {
                var juego: [String: MLMultiArray] = [:]
                for (nombre, entrada) in estados {
                    guard let forma = entrada.multiArrayConstraint?.shape.map(\.intValue) else {
                        throw SequenceBenchError.notStateful("\(nombre) no es un MLMultiArray")
                    }
                    juego[nombre] = try Self.surfaceArray(shape: forma)
                }
                sets.append(juego)
            }
            for p in 0..<2 {
                inputs.append(StepInputs(sets[p].mapValues { MLFeatureValue(multiArray: $0) }))
                let opcion = MLPredictionOptions()
                // La salida del paso con paridad p va al juego que leerá el paso siguiente.
                opcion.outputBackings = Dictionary(
                    uniqueKeysWithValues: sets[1 - p].map { ($0.key + explicitSuffix, $0.value) }
                )
                options.append(opcion)
            }
        }
        try reset()
    }

    /// El estado de antes del primer fotograma: cero.
    public func reset() throws {
        last = nil
        parity = 0
        switch mode {
        case .mlState:
            state = model.makeState()
        case .explicit:
            for juego in sets {
                for array in juego.values {
                    array.withUnsafeMutableBytes { crudo, _ in
                        guard let base = crudo.baseAddress else { return }
                        memset(base, 0, crudo.count)
                    }
                }
            }
        }
    }

    /// Un paso: el fotograma entra y el estado avanza. Devuelve las salidas del modelo.
    @discardableResult
    public func step(_ frame: MLFeatureValue) throws -> MLFeatureProvider {
        let salida: MLFeatureProvider
        switch mode {
        case .mlState:
            inputs[0].values[frameName] = frame
            salida = try model.prediction(from: inputs[0], using: state!, options: options[0])
        case .explicit:
            inputs[parity].values[frameName] = frame
            salida = try model.prediction(from: inputs[parity], options: options[parity])
            parity = 1 - parity
        }
        last = salida
        return salida
    }

    /// Lo que se compara con el dorado tras el último paso: la salida `name`, si no la
    /// salida `name_out` (el estado explícito) y, si no, el estado MLState `name`.
    public func values(_ name: String) throws -> [Float] {
        if let salida = last?.featureValue(for: name)?.multiArrayValue {
            return Self.floats(salida)
        }
        if let salida = last?.featureValue(for: name + suffix)?.multiArrayValue {
            return Self.floats(salida)
        }
        if let estado = state, model.modelDescription.stateDescriptionsByName[name] != nil {
            return estado.withMultiArray(for: name) { Self.floats($0) }
        }
        throw SequenceBenchError.missingValue(name)
    }

    // MARK: utilidades

    /// Un MLMultiArray fp16 sobre IOSurface (lo que el ANE lee y escribe sin copiar):
    /// la última dimensión es el ancho y el resto, las filas.
    static func surfaceArray(shape: [Int]) throws -> MLMultiArray {
        let ancho = shape.last ?? 1
        let alto = shape.dropLast().reduce(1, *)
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let codigo = CVPixelBufferCreate(
            nil, ancho, alto, kCVPixelFormatType_OneComponent16Half, attrs, &buffer
        )
        guard let listo = buffer else { throw SequenceBenchError.pixelBuffer(codigo) }
        return MLMultiArray(pixelBuffer: listo, shape: shape.map { NSNumber(value: $0) })
    }

    /// Cualquier MLMultiArray a [Float] en orden C, respetando sus strides (los de un
    /// IOSurface llevan relleno al final de cada fila).
    static func floats(_ array: MLMultiArray) -> [Float] {
        let forma = array.shape.map(\.intValue)
        let pasos = array.strides.map(\.intValue)
        let total = forma.reduce(1, *)
        var salida = [Float](repeating: 0, count: total)
        let tipo = array.dataType
        array.withUnsafeBytes { crudo in
            for i in 0..<total {
                var resto = i
                var desplazamiento = 0
                for d in stride(from: forma.count - 1, through: 0, by: -1) {
                    desplazamiento += (resto % forma[d]) * pasos[d]
                    resto /= forma[d]
                }
                switch tipo {
                case .float16:
                    salida[i] = Float(
                        crudo.loadUnaligned(fromByteOffset: desplazamiento * 2, as: Float16.self)
                    )
                case .float32:
                    salida[i] = crudo.loadUnaligned(fromByteOffset: desplazamiento * 4, as: Float.self)
                case .double:
                    salida[i] = Float(
                        crudo.loadUnaligned(fromByteOffset: desplazamiento * 8, as: Double.self)
                    )
                case .int32:
                    salida[i] = Float(
                        crudo.loadUnaligned(fromByteOffset: desplazamiento * 4, as: Int32.self)
                    )
                default:
                    salida[i] = .nan
                }
            }
        }
        return salida
    }
}

// MARK: - El banco de la secuencia

public enum SequenceBench {
    /// Pasos de desfase entre los dos recorridos intercalados: lo bastante para que el
    /// estado de uno no se parezca al del otro en ningún paso.
    public static let interleaveLag = 7

    public struct Result {
        public var mode: StateMode
        public var steps: Int
        public var goldenWorst: Double
        public var goldenViolations: Int
        public var repeatViolations: Int
        public var interleaveViolations: Int
        /// Percentiles EXACTOS por paso: el objetivo (1,7 ms) cae entre dos cubos del
        /// histograma de IOS-05, así que aquí se guardan las muestras en crudo.
        public var latency: BenchReport.StageSummary
    }

    private static let signposter = OSSignposter(
        subsystem: Signposts.subsystem, category: "sequence-bench"
    )

    /// Los fotogramas del bundle como los entrega la app: fp16 planar sobre IOSurface,
    /// byte·escala redondeado a fp16. Se preparan antes de medir nada.
    public static func frames(
        _ bundle: GoldenBundle, manifest: SequenceManifest
    ) throws -> [MLFeatureValue] {
        let escala = Float(manifest.frameScale)
        return try (0..<manifest.steps).map { paso in
            guard let item = bundle.input(base: manifest.frameInput, sample: paso) else {
                throw SequenceBenchError.missingFrame(paso)
            }
            let bytes = try bundle.data(item)
            let array = try SequenceStepper.surfaceArray(shape: item.shape)
            let ancho = item.shape.last ?? 1
            let pasoFila = array.strides[array.strides.count - 2].intValue
            array.withUnsafeMutableBytes { crudo, _ in
                let destino = crudo.bindMemory(to: Float16.self)
                bytes.withUnsafeBytes { (origen: UnsafeRawBufferPointer) in
                    let filas = item.count / ancho
                    for fila in 0..<filas {
                        for x in 0..<ancho {
                            let byte = origen[fila * ancho + x]
                            destino[fila * pasoFila + x] = Float16(Float(byte) * escala)
                        }
                    }
                }
            }
            return MLFeatureValue(multiArray: array)
        }
    }

    /// Recorre la secuencia entera desde donde esté el stepper (con `reset`, desde cero) y
    /// cuenta las salidas fuera de tolerancia contra el dorado.
    public static func runSequence(
        _ stepper: SequenceStepper,
        frames: [MLFeatureValue],
        bundle: GoldenBundle,
        manifest: SequenceManifest,
        reset: Bool = true
    ) throws -> (worst: Double, violations: Int) {
        if reset { try stepper.reset() }
        var peor = 0.0
        var violaciones = 0
        for paso in 0..<manifest.steps {
            try stepper.step(frames[paso])
            let (delta, fuera) = try compare(stepper, step: paso, bundle: bundle, manifest: manifest)
            peor = max(peor, delta)
            violaciones += fuera
        }
        return (peor, violaciones)
    }

    /// Las salidas del último paso contra las del paso `step` del dorado.
    static func compare(
        _ stepper: SequenceStepper, step: Int, bundle: GoldenBundle, manifest: SequenceManifest
    ) throws -> (worst: Double, violations: Int) {
        var peor = 0.0
        var violaciones = 0
        for base in manifest.outputs {
            guard let item = bundle.output(route: manifest.referenceRoute, base: base, sample: step)
            else {
                violaciones += 1
                continue
            }
            let esperado = try bundle.floats(item)
            let tolerancia = try bundle.tolerance(
                outputName: item.name, route: manifest.toleranceRoute
            )
            let visto = try stepper.values(base)
            guard visto.count == esperado.count else {
                violaciones += 1
                continue
            }
            var delta = 0.0
            for i in 0..<visto.count {
                delta = max(delta, Double(abs(visto[i] - esperado[i])))
            }
            if !(delta <= tolerancia) {  // un NaN también es una violación
                violaciones += 1
            }
            peor = max(peor, delta)
        }
        return (peor, violaciones)
    }

    /// El banco entero de un modelo en modo paso: dorado, reinicio, intercalado y latencia.
    public static func run(
        model: MLModel,
        bundle: GoldenBundle,
        manifest: SequenceManifest,
        warmup: Int,
        predictions: Int
    ) throws -> Result {
        let fotogramas = try frames(bundle, manifest: manifest)
        let a = try SequenceStepper(
            model: model, frameInput: manifest.frameInput, explicitSuffix: manifest.explicitSuffix
        )

        // 1. La secuencia contra el dorado, desde cero.
        let (peor, violaciones) = try runSequence(
            a, frames: fotogramas, bundle: bundle, manifest: manifest
        )
        // 2. Otra vez tras reiniciar: lo de la primera pasada no puede quedar dentro.
        let (_, repetidas) = try runSequence(
            a, frames: fotogramas, bundle: bundle, manifest: manifest
        )
        // 3. Dos recorridos intercalados sobre el mismo modelo, con desfase.
        let b = try SequenceStepper(
            model: model, frameInput: manifest.frameInput, explicitSuffix: manifest.explicitSuffix
        )
        try a.reset()
        var intercaladas = 0
        for i in 0..<(manifest.steps + interleaveLag) {
            if i < manifest.steps {
                try a.step(fotogramas[i])
                intercaladas += try compare(a, step: i, bundle: bundle, manifest: manifest).violations
            }
            if i >= interleaveLag {
                let paso = i - interleaveLag
                try b.step(fotogramas[paso])
                intercaladas += try compare(b, step: paso, bundle: bundle, manifest: manifest)
                    .violations
            }
        }

        // 4. La latencia por paso, con el estado vivo y los fotogramas del dorado en bucle.
        try a.reset()
        for i in 0..<warmup {
            try a.step(fotogramas[i % fotogramas.count])
        }
        var muestras = [Double](repeating: 0, count: predictions)  // reservado antes
        for i in 0..<predictions {
            let fotograma = fotogramas[i % fotogramas.count]
            let intervalo = signposter.beginInterval("step")
            let antes = ContinuousClock.now
            try a.step(fotograma)
            muestras[i] = ms(antes, ContinuousClock.now)
            signposter.endInterval("step", intervalo)
        }
        return Result(
            mode: a.mode,
            steps: manifest.steps,
            goldenWorst: peor,
            goldenViolations: violaciones,
            repeatViolations: repetidas,
            interleaveViolations: intercaladas,
            latency: DirectorBench.summary(muestras)
        )
    }

    private static func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = b - a
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }
}
