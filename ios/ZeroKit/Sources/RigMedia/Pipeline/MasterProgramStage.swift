// El programa del maestro: recepción, decodificación y composición (IOS-44, ADR 0023 §5).
//
// Las partes del esclavo pasan por la puerta de huecos (PartReceiver, IOS-52): solo una
// cadena entera llega al decodificador (IOS-51), y ante un hueco sale `idr_request`.
// Cada parte decodificada se apunta en ProgramSync (IOS-42) con la vista que trae.
//
// En cada tic del programa (T + PART_MAX_WAIT_MS), ProgramSync decide:
// - dos lentes: la mitad del maestro se pinta CON LA VISTA DE LA PARTE y con su fotograma
//   más cercano al instante de la parte, y se compone con la parte (IOS-41). Las dos
//   mitades salen de la misma vista y del mismo instante: no hay desgarro;
// - una lente: la parte no llegó a tiempo; el maestro pinta solo, con su vista, y se
//   cuenta.
//
// RigMedia no ve el enlace: las partes entran por `receive(part:)` y las peticiones de
// IDR salen por `onIdrRequest`; el Runner lo conecta a RigLinkSession.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import RigCore

/// Compone el programa de un instante; ComposeProgramKernel lo cumple con Metal.
public protocol ProgramComposing: AnyObject {
    func compose(
        master: CVPixelBuffer?, slave: CVPixelBuffer?, view: ViewCommand,
        into destination: CVPixelBuffer
    ) throws
}

/// La composición con el kernel de IOS-41, sin gráfico ni franja (IOS-47/48 los ponen).
public final class MetalProgramComposer: ProgramComposing {
    private let context: MetalContext
    private let kernel: ComposeProgramKernel
    private let masterSide: CameraSide
    private let width: Int
    private let height: Int

    public init(context: MetalContext, masterSide: CameraSide, width: Int, height: Int) throws {
        self.context = context
        kernel = try ComposeProgramKernel(context: context)
        self.masterSide = masterSide
        self.width = width
        self.height = height
    }

    public func compose(
        master: CVPixelBuffer?, slave: CVPixelBuffer?, view: ViewCommand,
        into destination: CVPixelBuffer
    ) throws {
        let vista = try RectilinearView(
            yawRad: view.yawRad, pitchRad: view.pitchRad, hfovRad: view.hfovRad,
            width: width, height: height
        )
        guard let buffer = context.queue.makeCommandBuffer() else {
            throw ReprojectKernelError.pipeline("no hay command buffer")
        }
        try kernel.encode(
            master: master, masterSide: masterSide, slave: slave, view: vista,
            seamYawRad: view.seamYawRad, featherRad: view.featherRad,
            graphic: nil, strip: nil, destination: destination, commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}

public final class MasterProgramStage {
    public struct Stats: Equatable, Sendable {
        public var partsReceived = 0
        public var partsDecoded = 0
        public var noParts = 0
        public var idrRequests = 0
        public var twoLensFrames = 0
        public var oneLensFrames = 0
        /// Instantes sin fotograma propio cerca: no se puede pintar nada.
        public var withoutMasterFrame = 0
        public var composeFailures = 0
    }

    /// Partes decodificadas que se guardan como mucho, esperando su tic.
    static let decodedSlots = 8

    public let masterSide: CameraSide
    private let receiver = PartReceiver()
    private let sync: ProgramSync
    private let decoder: VideoDecoder
    private let renderer: PartRendering
    private let composer: ProgramComposing
    private let masterPool: CVPixelBufferPool
    private let lock = NSLock()

    /// La vista con la que viene cada parte decodificada, por su instante.
    private var viewsByRigMs: [Int64: ResolvedView] = [:]
    private var decoded: [Int64: CVPixelBuffer] = [:]
    public private(set) var stats = Stats()

    /// El fotograma propio más cercano a un instante, del FrameRing (IOS-09). Devuelve el
    /// búfer y una función para soltarlo.
    public var masterFrame: ((Int64) -> (CVPixelBuffer, () -> Void)?)?

    /// Hay un hueco: hay que pedir un IDR al esclavo con este part_seq.
    public var onIdrRequest: ((UInt32) -> Void)?

    /// El programa de un instante, listo para el codificador del programa.
    public var onProgram: ((CVPixelBuffer, Int64) -> Void)?

    /// `masterPool`: NV12 del tamaño del programa, para pintar la mitad del maestro.
    public init(
        masterSide: CameraSide,
        frameDurationMs: Double,
        renderer: PartRendering,
        composer: ProgramComposing,
        masterPool: CVPixelBufferPool,
        decoder: VideoDecoder = VideoDecoder(),
        maxWaitMs: Int64 = LinkConstants.partMaxWaitMs
    ) {
        self.masterSide = masterSide
        sync = ProgramSync(frameDurationMs: frameDurationMs, maxWaitMs: maxWaitMs)
        self.decoder = decoder
        self.renderer = renderer
        self.composer = composer
        self.masterPool = masterPool
    }

    /// Una parte del esclavo, con su llegada en el reloj del soporte.
    public func receive(part: PartPacket, arrivalRigMs: Int64) {
        lock.lock()
        stats.partsReceived += 1
        let decision = receiver.receive(part, arrivalMs: arrivalRigMs)
        lock.unlock()
        switch decision {
        case let .decode(p):
            lock.lock()
            viewsByRigMs[p.frameRigMs] = ResolvedView(command: p.view, extrapolated: p.extrapolated)
            lock.unlock()
            decoder.decode(avcc: p.accessUnit, ptsNs: p.frameRigMs * 1_000_000)
            collectDecoded()
        case let .awaitingIdr(seq):
            lock.lock()
            stats.idrRequests += 1
            lock.unlock()
            onIdrRequest?(seq)
        case .dropOld:
            break
        }
    }

    public func receive(noPart _: NoPartPacket) {
        lock.lock()
        stats.noParts += 1
        lock.unlock()
    }

    /// Mbit/s y jitter de las partes, para la telemetría.
    public func linkStats(nowRigMs: Int64) -> (mbps: Double, jitterMs: Double, lost: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (receiver.mbps(nowMs: nowRigMs), receiver.jitterMs, receiver.lost)
    }

    /// Recoge lo que el decodificador ya terminó y lo apunta en ProgramSync.
    public func collectDecoded() {
        while let f = decoder.pop() {
            let rigMs = f.rigMs.map { Int64($0) } ?? f.ptsNs / 1_000_000
            lock.lock()
            if let vista = viewsByRigMs.removeValue(forKey: rigMs) {
                decoded[rigMs] = f.pixelBuffer
                sync.receive(PartInfo(frameRigMs: rigMs, view: vista))
                stats.partsDecoded += 1
                if decoded.count > Self.decodedSlots {
                    decoded.keys.sorted().prefix(decoded.count - Self.decodedSlots).forEach { decoded[$0] = nil }
                }
            }
            if viewsByRigMs.count > Self.decodedSlots * 4 {
                viewsByRigMs.keys.sorted().prefix(viewsByRigMs.count - Self.decodedSlots * 4)
                    .forEach { viewsByRigMs[$0] = nil }
            }
            lock.unlock()
        }
    }

    /// El tic del programa: compone el instante `programRigMs` si ya es su hora. `nil` si
    /// todavía no; si no, cómo salió.
    @discardableResult
    public func tick(programRigMs t: Int64, nowRigMs: Int64, masterView: ViewCommand) -> ProgramFrame? {
        collectDecoded()
        lock.lock()
        let decision = sync.compose(programRigMs: t, nowRigMs: nowRigMs, masterView: masterView)
        lock.unlock()
        guard let decision else { return nil }

        let vista: ViewCommand
        let instantePropio: Int64
        var parte: CVPixelBuffer?
        switch decision {
        case let .twoLens(v, slaveMs):
            vista = v
            instantePropio = slaveMs
            lock.lock()
            parte = decoded.removeValue(forKey: slaveMs)
            stats.twoLensFrames += 1
            lock.unlock()
        case let .oneLens(v):
            vista = v
            instantePropio = t
            lock.lock()
            stats.oneLensFrames += 1
            lock.unlock()
        }

        guard let (propio, soltar) = masterFrame?(instantePropio) else {
            lock.lock()
            stats.withoutMasterFrame += 1
            lock.unlock()
            return decision
        }
        defer { soltar() }
        var mitad: CVPixelBuffer?
        var programa: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, masterPool, &mitad)
        CVPixelBufferPoolCreatePixelBuffer(nil, masterPool, &programa)
        do {
            guard let mitad, let programa else {
                throw ReprojectKernelError.pipeline("el pool del programa no da búferes")
            }
            // Solo se pinta la mitad propia si la vista la pide: un encuadre que cae
            // entero en el esclavo no lleva nada del maestro.
            let conMaestro = parte == nil || vista.sides.contains(masterSide)
            if conMaestro {
                try renderer.render(source: propio, view: vista, into: mitad)
            }
            try composer.compose(
                master: conMaestro ? mitad : nil, slave: parte, view: vista, into: programa
            )
            onProgram?(programa, t)
        } catch {
            lock.lock()
            stats.composeFailures += 1
            lock.unlock()
        }
        return decision
    }
}
