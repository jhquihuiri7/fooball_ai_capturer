// La parte del esclavo: render, codificación y envío (IOS-43, ADR 0023 §5).
//
// Por cada fotograma del esclavo, de instante t:
// - toma la vista del maestro cuyo T está a ≤½ fotograma de t, o la extrapola
//   (SlaveViewResolver, IOS-42);
// - si la vista no necesita su lado, manda `no_part` y el maestro no espera;
// - si lo necesita, pinta su contribución (IOS-40) en un búfer del pool del codificador,
//   lo codifica en H.264 de baja latencia con la SEI (IOS-50) y manda la parte con la
//   vista que usó de verdad (IOS-52).
//
// La parte es siempre el ráster 1920×1080 entero, con negro donde su cámara no llega,
// para que la sesión de VideoToolbox no cambie de tamaño. RigMedia no ve el enlace:
// lo que sale va por `onPart`/`onNoPart`, y el Runner lo conecta a RigLinkSession.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import RigCore

/// Lo que la etapa necesita de un codificador; VideoEncoder lo cumple, y los tests
/// ponen uno falso.
public protocol PartEncoding: AnyObject {
    var pixelBufferPool: CVPixelBufferPool? { get }
    func forceIDR()
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64, rigMs: UInt64)
    func pop() -> EncodedFrame?
}

extension VideoEncoder: PartEncoding {}

/// Pinta la contribución de una cámara para una vista.
public protocol PartRendering: AnyObject {
    func render(source: CVPixelBuffer, view: ViewCommand, into destination: CVPixelBuffer) throws
}

/// El render de la parte con el kernel de reproyección (IOS-40).
public final class MetalPartRenderer: PartRendering {
    private let context: MetalContext
    private let kernel: ReprojectKernel
    private let rig: RigModel
    private let side: CameraSide
    private let width: Int
    private let height: Int
    private let blind: BlindRect?
    private let mountedUpsideDown: Bool

    /// `blind`: la franja del código de tiempo en el búfer de la cámara, si se pinta.
    /// `mountedUpsideDown`: el móvil va girado 180° en el soporte (CameraMount); por
    /// defecto el izquierdo, como `--flip left` en la calibración.
    public init(
        context: MetalContext, rig: RigModel, side: CameraSide, width: Int, height: Int,
        blind: BlindRect? = nil, mountedUpsideDown: Bool? = nil
    ) throws {
        self.mountedUpsideDown = mountedUpsideDown ?? (side == .left)
        self.context = context
        kernel = try ReprojectKernel(context: context)
        self.rig = rig
        self.side = side
        self.width = width
        self.height = height
        self.blind = blind
    }

    public func render(source: CVPixelBuffer, view: ViewCommand, into destination: CVPixelBuffer) throws {
        let vista = try RectilinearView(
            yawRad: view.yawRad, pitchRad: view.pitchRad, hfovRad: view.hfovRad,
            width: width, height: height
        )
        // Las ganancias viajan en el orden BGR de la referencia (`_apply_gain`).
        let g = side == .left ? view.gains.left : view.gains.right
        guard let buffer = context.queue.makeCommandBuffer() else {
            throw ReprojectKernelError.pipeline("no hay command buffer")
        }
        try kernel.encode(
            source: source,
            homography: mountedUpsideDown
                ? viewHomographyToRaw(rig: rig, view: vista, side: side)
                : viewHomography(rig: rig, view: vista, side: side),
            gains: g.count == 3 ? (b: g[0], g: g[1], r: g[2]) : (1, 1, 1),
            blind: blind,
            destination: destination,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}

public final class SlavePartStage {
    public struct Stats: Equatable, Sendable {
        public var parts = 0
        public var noParts = 0
        /// Fotogramas sin vista que usar: aún no ha llegado ninguna.
        public var withoutView = 0
        public var renderFailures = 0
        /// Partes que la cola del esclavo tiró (PartSendQueue).
        public var dropped = 0
        public var idrRequests = 0

        public init() {}
    }

    public let side: CameraSide
    private let resolver: SlaveViewResolver
    private let renderer: PartRendering
    private let encoder: PartEncoding
    private let sendQueue: PartSendQueue
    private let lock = NSLock()

    /// La vista con la que se pintó cada fotograma en vuelo por el codificador.
    private var inFlight: [UInt64: ResolvedView] = [:]
    private var nextPartSeq: UInt32 = 0
    public private(set) var stats = Stats()

    /// Una parte lista para el cable.
    public var onPart: ((PartPacket) -> Void)?
    /// Esta vista no necesita mi lado.
    public var onNoPart: ((NoPartPacket) -> Void)?

    public init(
        side: CameraSide,
        resolver: SlaveViewResolver,
        renderer: PartRendering,
        encoder: PartEncoding,
        sendQueue: PartSendQueue = PartSendQueue()
    ) {
        self.side = side
        self.resolver = resolver
        self.renderer = renderer
        self.encoder = encoder
        self.sendQueue = sendQueue
    }

    /// Las vistas que manda el maestro (`view`).
    public func receive(views: [ViewCommand]) {
        lock.lock()
        defer { lock.unlock() }
        resolver.receive(views)
    }

    /// El maestro tiene un hueco (`idr_request`): el siguiente fotograma sale IDR.
    public func requestIdr() {
        lock.lock()
        sendQueue.requestIdr()
        stats.idrRequests += 1
        lock.unlock()
        encoder.forceIDR()
    }

    /// Un fotograma del esclavo, de instante `frameRigMs` en el reloj del soporte.
    public func process(frame: CVPixelBuffer, frameRigMs: Int64, ptsNs: Int64) {
        lock.lock()
        let resuelta = resolver.resolve(frameRigMs: frameRigMs)
        let necesitaIdr = sendQueue.needsIdr
        lock.unlock()

        guard let resuelta else {
            lock.lock()
            stats.withoutView += 1
            lock.unlock()
            drain()
            return
        }
        guard resuelta.command.sides.contains(side) else {
            lock.lock()
            stats.noParts += 1
            lock.unlock()
            onNoPart?(NoPartPacket(frameRigMs: frameRigMs, viewId: resuelta.command.viewId))
            drain()
            return
        }

        var destino: CVPixelBuffer?
        if let pool = encoder.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destino)
        }
        guard let destino else {
            lock.lock()
            stats.renderFailures += 1
            lock.unlock()
            return
        }
        do {
            try renderer.render(source: frame, view: resuelta.command, into: destino)
        } catch {
            lock.lock()
            stats.renderFailures += 1
            lock.unlock()
            return
        }
        if necesitaIdr {
            encoder.forceIDR()
        }
        let rigMs = UInt64(max(0, frameRigMs))
        lock.lock()
        inFlight[rigMs] = resuelta
        // Acotado: lo que el codificador no devolvió en un segundo ya no vuelve.
        if inFlight.count > SlavePartStage.maxInFlight {
            inFlight.keys.sorted().prefix(inFlight.count - SlavePartStage.maxInFlight)
                .forEach { inFlight[$0] = nil }
        }
        lock.unlock()
        encoder.encode(destino, ptsNs: ptsNs, rigMs: rigMs)
        drain()
    }

    /// Fotogramas en vuelo por el codificador que se recuerdan como mucho (1 s a 30 fps).
    static let maxInFlight = 30

    /// Lo que el codificador ya devolvió, en partes hacia el cable.
    public func drain() {
        while let codificado = encoder.pop() {
            lock.lock()
            guard let vista = inFlight.removeValue(forKey: codificado.rigMs) else {
                lock.unlock()
                continue
            }
            var unidad = codificado.data
            if codificado.isKeyframe, let formato = codificado.formatDescription {
                // Los SPS/PPS en banda, pegados al IDR: el maestro arranca con él solo.
                unidad = H264ParameterSets.avccNals(from: formato) + unidad
            }
            let parte = PartPacket(
                partSeq: nextPartSeq,
                frameRigMs: Int64(codificado.rigMs),
                view: vista.command,
                extrapolated: vista.extrapolated,
                isKey: codificado.isKeyframe,
                accessUnit: unidad
            )
            if sendQueue.push(parte) {
                // Solo las que salen consumen part_seq: una tirada aquí no es un hueco
                // para el maestro, y la que la sigue ya es el IDR.
                nextPartSeq &+= 1
            } else {
                stats.dropped += 1
            }
            var salientes: [PartPacket] = []
            while let p = sendQueue.pop() {
                salientes.append(p)
            }
            stats.parts += salientes.count
            lock.unlock()
            salientes.forEach { onPart?($0) }
        }
    }
}
