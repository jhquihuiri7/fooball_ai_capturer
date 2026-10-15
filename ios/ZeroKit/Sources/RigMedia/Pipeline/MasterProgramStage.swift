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
    /// `atRigMs`: el instante del programa, que elige el fotograma de la franja.
    func compose(
        master: CVPixelBuffer?, slave: CVPixelBuffer?, view: ViewCommand, atRigMs: Int64,
        into destination: CVPixelBuffer
    ) throws
    /// SPK-04: la GPU de la última composición, en ms; nil si no lo sabe.
    var lastGpuMs: Double? { get }
}

extension ProgramComposing {
    public var lastGpuMs: Double? { nil }
}

/// Lo que se pintó en un instante del programa (SPK-04): la vista de verdad, los
/// fotogramas de cada móvil y la GPU. Con esto, la referencia de Python (REF-41) rehace
/// el mismo fotograma desde las 4K.
public struct ComposedFrame: Sendable {
    public let programRigMs: Int64
    public let source: ProgramSource
    public let view: ViewCommand
    /// El instante del fotograma propio usado; nil si no lo hubo o no se pintó.
    public let masterFrameRigMs: Int64?
    /// El de la parte del esclavo; nil sin parte.
    public let partFrameRigMs: Int64?
    /// La parte se pintó con una vista extrapolada (el esclavo no tenía la suya).
    public let extrapolated: Bool
    public let torn: Bool
    /// Render de la mitad propia más composición, en ms de GPU; nil si no se supo.
    public let gpuMs: Double?
}

/// La composición con el kernel de IOS-41, con el gráfico de Dart (IOS-47) y la franja
/// de anuncios (IOS-48) si los hay.
public final class MetalProgramComposer: ProgramComposing {
    /// El gráfico que manda Dart (marcador, alineación, SIN SEÑAL).
    public var overlay: OverlayStore?
    /// La franja de anuncios (IOS-48).
    public var ads: AdRotation?

    private let context: MetalContext
    private let kernel: ComposeProgramKernel
    private let masterSide: CameraSide
    private let width: Int
    private let height: Int
    public private(set) var lastGpuMs: Double?

    public init(context: MetalContext, masterSide: CameraSide, width: Int, height: Int) throws {
        self.context = context
        kernel = try ComposeProgramKernel(context: context)
        self.masterSide = masterSide
        self.width = width
        self.height = height
    }

    public func compose(
        master: CVPixelBuffer?, slave: CVPixelBuffer?, view: ViewCommand, atRigMs: Int64,
        into destination: CVPixelBuffer
    ) throws {
        let vista = try RectilinearView(
            yawRad: view.yawRad, pitchRad: view.pitchRad, hfovRad: view.hfovRad,
            width: width, height: height
        )
        guard let buffer = context.queue.makeCommandBuffer() else {
            throw ReprojectKernelError.pipeline("no hay command buffer")
        }
        let grafico = overlay?.beginFrame()
        defer { if grafico != nil { overlay?.endFrame() } }
        try kernel.encode(
            master: master, masterSide: masterSide, slave: slave, view: vista,
            seamYawRad: view.seamYawRad, featherRad: view.featherRad,
            graphic: grafico, strip: ads?.strip(atRigMs: atRigMs)?.0,
            destination: destination, commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        lastGpuMs = GpuTiming.milliseconds(buffer)
        // La GPU ya soltó las texturas de este fotograma: fuera las entradas muertas.
        context.flushTextureCache()
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
        /// SPK-04: dos lentes con las mitades de vistas o instantes distintos (TearCheck).
        public var tornFrames = 0
        /// Dos lentes con la vista extrapolada por el esclavo (no es desgarro: las dos
        /// mitades la usan; es una vista que el director no dio).
        public var extrapolatedViewFrames = 0

        public init() {}
    }

    /// Partes decodificadas que se guardan como mucho, esperando su tic.
    static let decodedSlots = 8

    public let masterSide: CameraSide
    /// Las veces que el decodificador de las partes tiró una sesión invalidada (2026-10-14).
    public var decoderSessionResets: Int { decoder.sessionResets }
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
    /// Las partes decodificadas que vinieron con la vista extrapolada, por su instante.
    private var extrapolatedParts: Set<Int64> = []
    public private(set) var stats = Stats()
    /// IOS-43: la edad de cada parte al llegar (su llegada menos la captura del esclavo,
    /// los dos en el reloj del soporte), en ms.
    public private(set) var partAge = LatencyHistogram(boundsMs: MasterProgramStage.partAgeBoundsMs)
    /// IOS-52: de la primera petición de IDR por un hueco a la llegada del fotograma clave
    /// que lo cierra, en ms.
    public private(set) var idrRecovery = LatencyHistogram(boundsMs: MasterProgramStage.partAgeBoundsMs)
    private var idrAskedMs: Int64?
    /// SPK-04: la GPU por fotograma (render de la mitad propia + composición) y la de la
    /// composición sola, en ms.
    public private(set) var gpuMs = LatencyHistogram(boundsMs: GpuTiming.boundsMs)
    public private(set) var composeGpuMs = LatencyHistogram(boundsMs: GpuTiming.boundsMs)
    /// SPK-04: |captura del maestro − captura de la parte| en los de dos lentes, en ms (la
    /// fase entre las cámaras; ADR 0012 la quiere ≤5 ms).
    public private(set) var halvesSkewMs = LatencyHistogram()
    /// SPK-04 (2026-10-14): la misma fase con signo, minuto a minuto, con los desgarros de
    /// cada minuto (HalvesPhaseTracker): la fase deriva y los desgarros salen al cruzar ½
    /// fotograma. La pone quien sabe cuándo arrancó la pasada.
    public var halvesPhase: HalvesPhaseTracker?
    private let frameDurationMs: Double
    /// Cubos de 5 ms hasta 150 (la aceptación de IOS-43 es p95 ≤60) y gruesos después.
    public static let partAgeBoundsMs: [Double] = stride(from: 5, through: 150, by: 5).map(Double.init)
        + [200, 300, 500, 1000, 2000]

    /// El esclavo está caído (IOS-81): no se espera su parte; cada instante se compone en
    /// cuanto toca, de una lente.
    public var peerDown = false {
        didSet {
            lock.lock()
            sync.maxWaitMs = peerDown ? 0 : waitWithPeer
            lock.unlock()
        }
    }
    private var waitWithPeer: Int64 = LinkConstants.partMaxWaitMs

    /// El fotograma propio más cercano a un instante, del FrameRing (IOS-09). Devuelve el
    /// búfer, su instante y una función para soltarlo.
    public var masterFrame: ((Int64) -> (CVPixelBuffer, Int64, () -> Void)?)?

    /// Cada instante pintado, con lo que llevó (SPK-04).
    public var onComposed: ((ComposedFrame) -> Void)?

    /// Hay un hueco: hay que pedir un IDR al esclavo con este part_seq.
    public var onIdrRequest: ((UInt32) -> Void)?

    /// El programa de un instante, listo para el codificador del programa.
    public var onProgram: ((CVPixelBuffer, Int64) -> Void)?

    /// Cada cambio de fuente del programa (IOS-84): quien tiene el gráfico enseña SIN
    /// SEÑAL al llegar a `.noSignal`.
    public var onSourceChange: ((ProgramSource) -> Void)?
    public private(set) var sources = ProgramSourceStats()
    /// El último programa con imagen, para repetirlo hasta PROGRAM_HOLD_MS.
    private var lastProgram: CVPixelBuffer?

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
        self.frameDurationMs = frameDurationMs
        waitWithPeer = maxWaitMs
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
        partAge.record(ms: Double(arrivalRigMs - part.frameRigMs))
        let decision = receiver.receive(part, arrivalMs: arrivalRigMs)
        if case let .decode(p) = decision, p.isKey, let pedido = idrAskedMs {
            idrRecovery.record(ms: Double(arrivalRigMs - pedido))
            idrAskedMs = nil
        }
        if case .awaitingIdr = decision, idrAskedMs == nil {
            idrAskedMs = arrivalRigMs
        }
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
                if vista.extrapolated { extrapolatedParts.insert(rigMs) }
                if extrapolatedParts.count > Self.decodedSlots {
                    extrapolatedParts.sorted().prefix(extrapolatedParts.count - Self.decodedSlots)
                        .forEach { extrapolatedParts.remove($0) }
                }
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

        let propioLease = masterFrame?(instantePropio)
        defer { propioLease?.2() }
        lock.lock()
        let fuente = ProgramClock.choose(
            masterFrame: propioLease != nil, slavePart: parte != nil, instantMs: t,
            lastRealFrameMs: sources.lastRealFrameMs
        )
        let anterior = sources.current
        sources.record(fuente, instantMs: t)
        if propioLease == nil { stats.withoutMasterFrame += 1 }
        lock.unlock()
        if fuente != anterior { onSourceChange?(fuente) }

        if fuente == .hold, let ultimo = lastProgram {
            onComposed?(ComposedFrame(programRigMs: t, source: fuente, view: vista, masterFrameRigMs: nil,
                                      partFrameRigMs: nil, extrapolated: false, torn: false, gpuMs: nil))
            onProgram?(ultimo, t)
            return decision
        }
        var mitad: CVPixelBuffer?
        var programa: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, masterPool, &mitad)
        CVPixelBufferPoolCreatePixelBuffer(nil, masterPool, &programa)
        do {
            guard let mitad, let programa else {
                throw ReprojectKernelError.pipeline("el pool del programa no da búferes")
            }
            // Solo se pinta la mitad propia si hay fotograma y la vista la pide (o es lo
            // único que hay): un encuadre que cae entero en el esclavo no lleva nada suyo.
            var conMaestro = false
            var gpuMitad: Double? = 0
            if let (propio, _, _) = propioLease, parte == nil || vista.sides.contains(masterSide) {
                try renderer.render(source: propio, view: vista, into: mitad)
                conMaestro = true
                gpuMitad = renderer.lastGpuMs
            }
            // SIN SEÑAL: ni maestro ni parte; sale el gráfico (con la tarjeta) sobre negro.
            try composer.compose(
                master: conMaestro ? mitad : nil, slave: parte, view: vista, atRigMs: t, into: programa
            )
            noteComposed(t: t, source: fuente, decision: decision, view: vista,
                         masterFrameRigMs: conMaestro ? propioLease?.1 : nil, withPart: parte != nil,
                         gpuMs: gpuMitad.flatMap { m in composer.lastGpuMs.map { m + $0 } })
            if fuente != .noSignal { lastProgram = programa }
            onProgram?(programa, t)
        } catch {
            lock.lock()
            stats.composeFailures += 1
            lock.unlock()
        }
        return decision
    }

    /// Las cuentas de SPK-04 de un instante pintado: GPU, desgarro y fase entre mitades.
    private func noteComposed(
        t: Int64, source: ProgramSource, decision: ProgramFrame, view: ViewCommand,
        masterFrameRigMs: Int64?, withPart: Bool, gpuMs gpu: Double?
    ) {
        var parteMs: Int64?
        var extrapolada = false
        var desgarro = false
        lock.lock()
        if let gpu { gpuMs.record(ms: gpu) }
        if let c = composer.lastGpuMs { composeGpuMs.record(ms: c) }
        if case let .twoLens(vistaParte, slaveMs) = decision, withPart {
            parteMs = slaveMs
            extrapolada = extrapolatedParts.remove(slaveMs) != nil
            if extrapolada { stats.extrapolatedViewFrames += 1 }
            if let propio = masterFrameRigMs {
                halvesSkewMs.record(ms: abs(Double(propio - slaveMs)))
                desgarro = TearCheck.isTorn(masterView: view, partView: vistaParte, masterFrameRigMs: propio,
                                            partFrameRigMs: slaveMs, frameDurationMs: frameDurationMs)
                if desgarro { stats.tornFrames += 1 }
                halvesPhase?.record(atRigMs: t, skewMs: Double(propio - slaveMs), torn: desgarro)
            }
        }
        lock.unlock()
        onComposed?(ComposedFrame(programRigMs: t, source: source, view: view, masterFrameRigMs: masterFrameRigMs,
                                  partFrameRigMs: parteMs, extrapolated: extrapolada, torn: desgarro, gpuMs: gpu))
    }
}
