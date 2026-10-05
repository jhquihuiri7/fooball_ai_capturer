// El ejecutor Core ML del móvil (IOS-22): ANE, salidas preasignadas y carriles.
//
// - MLModelConfiguration con .cpuAndNeuralEngine (el contrato de latencia del ADR 0020)
//   y, donde existe, la pista de que la forma de la entrada no cambia.
// - Antes de servir, se comprueba contra su manifiesto (ModelManifest) y se calienta.
// - Cada carril tiene sus búferes de salida preasignados (MLPredictionOptions.
//   outputBackings): una predicción no reserva memoria para sus salidas.
// - Una cola serie con carriles de prioridad: las ROIs del balón pasan por delante de los
//   jugadores, y cada carril guarda como mucho UNA petición: una nueva sustituye a la que
//   esperaba (se cuenta). Nunca se encola latencia.
// - Signposts y un histograma por carril.

import CoreML
import CoreVideo
import Foundation
import RigCore

public final class CoreMLRunner: @unchecked Sendable {
    /// Por orden de prioridad: el balón antes que los jugadores.
    public enum Lane: Int, CaseIterable, Sendable {
        case ball = 0
        case players = 1
    }

    /// Lo que sale de una predicción: las salidas (los búferes del carril: valen hasta la
    /// siguiente predicción de ese carril) y lo que tardó.
    public struct Output {
        public let arrays: [String: MLMultiArray]
        public let inferMs: Double
    }

    public static let warmupPredictions = 3

    public let entry: ModelManifest.Entry
    private let model: MLModel
    private let queue = DispatchQueue(label: "io.footballai.zero.coreml", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [Lane: (MLFeatureProvider, (Result<Output, Error>) -> Void)] = [:]
    private var busy = false
    private var backings: [Lane: [String: MLMultiArray]] = [:]

    public private(set) var dropped: [Lane: Int] = [:]
    public private(set) var completed: [Lane: Int] = [:]
    private var histograms: [Lane: LatencyHistogram] = [:]

    /// Carga el modelo (`.mlpackage` se compila; `.mlmodelc` se abre tal cual), lo
    /// comprueba contra su manifiesto y prepara las salidas de cada carril.
    public static func load(
        url: URL, entry: ModelManifest.Entry, computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws -> CoreMLRunner {
        let compilado = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        if #available(iOS 17.4, macOS 14.4, *) {
            config.optimizationHints.reshapeFrequency = .infrequent
        }
        let model = try MLModel(contentsOf: compilado, configuration: config)
        try entry.check(against: model.modelDescription)
        return try CoreMLRunner(model: model, entry: entry)
    }

    init(model: MLModel, entry: ModelManifest.Entry) throws {
        self.model = model
        self.entry = entry
        for lane in Lane.allCases {
            var porNombre: [String: MLMultiArray] = [:]
            for (nombre, d) in model.modelDescription.outputDescriptionsByName {
                guard let c = d.multiArrayConstraint else { continue }
                porNombre[nombre] = try MLMultiArray(shape: c.shape, dataType: c.dataType)
            }
            backings[lane] = porNombre
            histograms[lane] = LatencyHistogram()
            dropped[lane] = 0
            completed[lane] = 0
        }
    }

    /// Unas predicciones de calentado (la primera en el ANE carga y planifica). Devuelve
    /// lo que tardó en total, en ms.
    @discardableResult
    public func warmUp(with input: MLFeatureProvider, predictions: Int = warmupPredictions) throws -> Double {
        let inicio = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<predictions {
            _ = try predict(input, lane: .players)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6
    }

    /// Pide una predicción en un carril. Si ya había una esperando en ese carril, la
    /// sustituye (y la vieja recibe `CancellationError`).
    public func submit(_ input: MLFeatureProvider, lane: Lane, completion: @escaping (Result<Output, Error>) -> Void) {
        lock.lock()
        if let vieja = pending[lane] {
            dropped[lane, default: 0] += 1
            queue.async { vieja.1(.failure(CancellationError())) }
        }
        pending[lane] = (input, completion)
        let arrancar = !busy
        busy = true
        lock.unlock()
        if arrancar { queue.async { [self] in drain() } }
    }

    /// p50/p99 de un carril, en ms.
    public func percentiles(_ lane: Lane) -> (p50: Double, p99: Double) {
        lock.lock(); defer { lock.unlock() }
        let h = histograms[lane]!
        return (h.percentile(0.5), h.percentile(0.99))
    }

    // MARK: - Dentro (en la cola serie)

    private func drain() {
        while true {
            lock.lock()
            guard let lane = Lane.allCases.first(where: { pending[$0] != nil }), let (entrada, fin) = pending[lane] else {
                busy = false
                lock.unlock()
                return
            }
            pending[lane] = nil
            lock.unlock()
            let estado = Signposts.begin(.infer)
            let resultado = Result { try predict(entrada, lane: lane) }
            Signposts.end(.infer, estado)
            if case let .success(o) = resultado {
                lock.lock()
                histograms[lane]?.record(ms: o.inferMs)
                completed[lane, default: 0] += 1
                lock.unlock()
            }
            fin(resultado)
        }
    }

    private func predict(_ input: MLFeatureProvider, lane: Lane) throws -> Output {
        let opciones = MLPredictionOptions()
        let mios = backings[lane] ?? [:]
        opciones.outputBackings = mios
        let inicio = DispatchTime.now().uptimeNanoseconds
        let salida = try model.prediction(from: input, options: opciones)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6
        var arrays: [String: MLMultiArray] = [:]
        for nombre in salida.featureNames {
            arrays[nombre] = salida.featureValue(for: nombre)?.multiArrayValue
        }
        return Output(arrays: arrays, inferMs: ms)
    }
}
