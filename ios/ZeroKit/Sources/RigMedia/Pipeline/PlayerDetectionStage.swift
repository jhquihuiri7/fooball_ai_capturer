// La etapa de detección de jugadores (IOS-25): cadencia anclada al reloj del soporte.
//
// Por cada fotograma que entra al anillo, si ya pasó el siguiente instante de la rejilla
// t_k = k / hz (DetectionCadence), se toma del anillo el fotograma más cercano a t_k (a
// ≤½ fotograma) y se lanza la cadena: preproceso (IOS-21) → inferencia (IOS-22) →
// decodificación (IOS-23) → CameraDetections. Igual en los dos móviles, sin mensajes:
// sus detecciones son del mismo instante.
//
// Una sola detección en vuelo: si la anterior no ha acabado cuando toca la siguiente, la
// siguiente se descarta y se cuenta (colas acotadas siempre). La cadencia común la fija
// el maestro (el mínimo de las dos escaleras) con `setCadence`.

import CoreML
import CoreVideo
import Foundation
import RigCore

/// Las detecciones de una cámara en un instante del soporte.
public struct CameraDetections: Sendable {
    public let side: CameraSide
    /// El instante de la rejilla al que corresponden (t_k).
    public let targetRigMs: Int64
    /// El instante del fotograma que se usó.
    public let frameRigMs: Int64
    public let detections: [PlayerDetection]
    public let inferMs: Double
}

/// La cadena de una detección: del fotograma a las cajas nativas. La de verdad junta
/// DetectorInputBuilder, CoreMLRunner y PlayerDecoder; los tests ponen una falsa.
public protocol PlayerDetecting: AnyObject {
    /// Detecta en `frame` y llama a `completion` (en cualquier hilo) con las cajas y lo
    /// que tardó la inferencia, o con el error.
    func detect(_ frame: CVPixelBuffer, completion: @escaping (Result<([PlayerDetection], Double), Error>) -> Void)
}

public final class PlayerDetectionStage {
    public struct Stats: Equatable, Sendable {
        public var detections = 0
        /// Instantes que tocaban con una detección aún en vuelo.
        public var droppedBusy = 0
        /// Instantes sin fotograma a ≤½ fotograma en el anillo.
        public var missingFrame = 0
        public var failures = 0
        public init() {}
    }

    public let side: CameraSide
    private let ring: FrameRing
    private let detector: PlayerDetecting
    private let halfFrameMs: Int64
    private let lock = NSLock()
    private var cadence: DetectionCadence
    private var nextTarget: Int64?
    private var inFlight = false
    public private(set) var stats = Stats()

    /// Las detecciones de cada instante. En el maestro van a la fusión; en el esclavo, al
    /// enlace (`detections`).
    public var onDetections: ((CameraDetections) -> Void)?

    public init(
        side: CameraSide, ring: FrameRing, detector: PlayerDetecting,
        cadence: DetectionCadence = DetectionCadence(), frameDurationMs: Double = 1000.0 / 30.0
    ) {
        self.side = side
        self.ring = ring
        self.detector = detector
        self.cadence = cadence
        halfFrameMs = Int64((frameDurationMs / 2).rounded(.up))
    }

    /// La cadencia común que manda el maestro.
    public func setCadence(_ c: DetectionCadence) {
        lock.lock(); defer { lock.unlock() }
        cadence = c
        nextTarget = nil
    }

    /// Un fotograma acaba de entrar al anillo (RigPipeline.onFrame).
    public func frameStored(rigMs: Int64) {
        lock.lock()
        let objetivo = nextTarget ?? cadence.next(after: rigMs - halfFrameMs)
        // Aún no: el fotograma de después del instante es el que permite elegir.
        guard rigMs >= objetivo else {
            nextTarget = objetivo
            lock.unlock()
            return
        }
        nextTarget = cadence.next(after: objetivo)
        if inFlight {
            stats.droppedBusy += 1
            lock.unlock()
            return
        }
        guard let lease = ring.acquire(nearest: objetivo, maxDistanceMs: halfFrameMs) else {
            stats.missingFrame += 1
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        detector.detect(lease.buffer) { [weak self] resultado in
            guard let self else { return }
            ring.release(lease)
            lock.lock()
            inFlight = false
            switch resultado {
            case let .success((cajas, ms)):
                stats.detections += 1
                lock.unlock()
                onDetections?(CameraDetections(
                    side: side, targetRigMs: objetivo, frameRigMs: lease.rigMs, detections: cajas, inferMs: ms
                ))
            case .failure:
                stats.failures += 1
                lock.unlock()
            }
        }
    }
}

/// La cadena de verdad (IOS-25): la franja del NV12 a la entrada del modelo en la GPU
/// (DetectorInputBuilder, IOS-21), la inferencia en el ANE por el carril de jugadores
/// (CoreMLRunner, IOS-22) y las cajas a nativo (PlayerDecoder, IOS-23) con el layout de
/// band.json.
public final class CoreMLPlayerDetector: PlayerDetecting {
    private let builder: DetectorInputBuilder
    private let runner: CoreMLRunner
    private let decoder: PlayerDecoder
    private let layout: InputLayout
    private let inputName: String
    private let logitsName: String
    private let boxesName: String

    public init(builder: DetectorInputBuilder, runner: CoreMLRunner, layout: InputLayout) throws {
        let e = runner.entry
        guard let logits = e.output(meaning: "logits"),
              let boxes = e.output(meaning: "boxes_cxcywh_norm") ?? e.output(meaning: "boxes_xyxy_input_px")
        else {
            throw ModelManifest.ManifestError.invalid("\(e.name): faltan las salidas de logits y cajas")
        }
        self.builder = builder
        self.runner = runner
        self.layout = layout
        inputName = e.input.name
        logitsName = logits.name
        boxesName = boxes.name
        decoder = try PlayerDecoder(
            classNames: e.classes,
            postprocess: PlayerDecoder.Postprocessing(rawValue: e.postprocess) ?? .detr,
            boxFormat: PlayerDecoder.BoxFormat(rawValue: e.boxFormat) ?? .cxcywhNorm,
            nmsIou: e.postprocess == "nms" ? DetectionSpec.nmsIouThreshold : nil
        )
    }

    public func detect(
        _ frame: CVPixelBuffer, completion: @escaping (Result<([PlayerDetection], Double), Error>) -> Void
    ) {
        do {
            try builder.build(from: frame) { [self] entrada in
                guard let entrada else {
                    completion(.failure(CancellationError()))  // sin hueco en el pool: descartado y contado
                    return
                }
                do {
                    let proveedor = try MLDictionaryFeatureProvider(
                        dictionary: [inputName: MLFeatureValue(pixelBuffer: entrada)]
                    )
                    runner.submit(proveedor, lane: .players) { [self] resultado in
                        completion(resultado.flatMap { salida in
                            Result {
                                guard let l = salida.arrays[logitsName], let b = salida.arrays[boxesName] else {
                                    throw ModelManifest.ManifestError.invalid("el modelo no devolvió logits y cajas")
                                }
                                let dets = try decoder.decode(
                                    logits: Self.rows(l), boxes: Self.rows(b), layout: layout
                                )
                                return (dets, salida.inferMs)
                            }
                        })
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// [1, Q, K] → Q filas de K Float (fp16 o fp32).
    static func rows(_ a: MLMultiArray) -> [[Float]] {
        let forma = a.shape.map(\.intValue)
        let q = forma.count >= 2 ? forma[forma.count - 2] : 1
        let k = forma.last ?? 0
        return (0..<q).map { i in (0..<k).map { j in a[i * k + j].floatValue } }
    }
}
