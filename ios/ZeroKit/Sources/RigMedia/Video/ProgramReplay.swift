// La repetición al aire (IOS-118, ADR 0034): un tramo del programa ya emitido, otra vez en el
// programa.
//
// El tramo sale del anillo (ProgramRing) y se escribe sin recodificar en un .mov temporal: el
// H.264 tal cual, desde el IDR anterior a la marca, sin tiempo real (no se descarta nada).
// Lo pasa el mismo ProgramVideoPlayer de los vídeos del mando, con su escalado a 1080p y su
// pool preasignado, pero leyendo desde el instante exacto y sin sonido: el del directo sigue.
//
// El hub decide qué instantes del programa son de la repetición: desde el corte de entrada,
// que fija al tenerla preparada, hasta el de vuelta. Dart pinta la cortinilla con los mismos
// instantes; el corte cae en el centro del tramo tapado.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RigCore

/// Escribe un tramo del anillo en un .mov sin recodificar.
enum ReplayClipWriter {
    enum WriterError: Error, Equatable {
        case noFrames
        case cannotAdd
        case failed(String)
    }

    /// Cola de las muestras: el escritor pide las siguientes cuando puede con ellas.
    private static let queue = DispatchQueue(label: "io.footballai.zero.replay.writer", qos: .userInitiated)

    /// Por dónde va la escritura. Solo la toca la cola del escritor, una llamada a la vez; va
    /// en una clase porque el bloque del escritor es `@Sendable` y no puede cambiar variables.
    private final class Progreso: @unchecked Sendable {
        var siguiente = 0
        var hecho = false
    }

    /// `frames` empieza en un IDR y va con un solo formato (el anillo lo garantiza). El último
    /// dura `lastDurationNs`; los demás, hasta el siguiente.
    static func write(_ frames: [EncodedFrame], to url: URL, lastDurationNs: Int64) async throws {
        guard let primero = frames.first, let formato = primero.formatDescription else {
            throw WriterError.noFrames
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formato)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw WriterError.cannotAdd }
        writer.add(input)
        // `let`: el bloque del escritor es `@Sendable` y no puede capturar variables.
        let muestras: [CMSampleBuffer] = try frames.indices.map { i in
            let f = frames[i]
            let dura = i + 1 < frames.count ? frames[i + 1].ptsNs - f.ptsNs : lastDurationNs
            return try ProgramRecorder.sample(
                f.data, format: f.formatDescription ?? formato, ptsNs: f.ptsNs - primero.ptsNs,
                durationNs: dura, sync: f.isKeyframe
            )
        }
        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "no empieza a escribir")
        }
        writer.startSession(atSourceTime: .zero)
        let progreso = Progreso()
        try await withCheckedThrowingContinuation { (fin: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !progreso.hecho else { return }
                while input.isReadyForMoreMediaData, progreso.siguiente < muestras.count {
                    guard input.append(muestras[progreso.siguiente]) else {
                        progreso.hecho = true
                        let porque = writer.error?.localizedDescription ?? "no admite una muestra"
                        writer.cancelWriting()
                        fin.resume(throwing: WriterError.failed(porque))
                        return
                    }
                    progreso.siguiente += 1
                }
                guard progreso.siguiente == muestras.count else { return }
                progreso.hecho = true
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        fin.resume()
                    } else {
                        fin.resume(throwing: WriterError.failed(writer.error?.localizedDescription ?? "no cierra"))
                    }
                }
            }
        }
    }
}

public final class ProgramReplayHub {
    /// Una repetición preparada: lo que se repite, `[fromRigMs, toRigMs)`, y el instante del
    /// programa en que entra. Vuelve el directo en `cutRigMs + (toRigMs − fromRigMs)`.
    public struct Armed: Equatable, Sendable {
        public let id: Int64
        public let fromRigMs: Int64
        public let toRigMs: Int64
        public let cutRigMs: Int64
    }

    public enum ReplayError: Error, Equatable {
        /// Ya hay una repetición preparándose o al aire.
        case busy
        /// La cortaron mientras se preparaba.
        case cancelled
        case ring(ProgramRing.RingError)
        case clip(String)
    }

    private struct Playing {
        let id: Int64
        let player: ProgramVideoPlayer
        let url: URL
        let cutRigMs: Int64
        var endRigMs: Int64
    }

    public let ring: ProgramRing
    private let directory: URL
    private let width: Int
    private let height: Int
    /// La repetición más corta que se prepara, en ms (`replay.min_s`).
    private let minimumMs: Int64

    // Con `lock`.
    private let lock = NSLock()
    private var current: Playing?
    private var preparing: Int64?
    private var cancelled: Set<Int64> = []
    /// Fotogramas que la repetición ha puesto en el programa, para el informe.
    public private(set) var framesServed = 0

    public init(
        ring: ProgramRing = ProgramRing(), directory: URL = FileManager.default.temporaryDirectory,
        width: Int, height: Int,
        minimumMs: Int64 = Int64(OverlaySpec.replay["min_s"] ?? 0) * 1000
    ) {
        self.ring = ring
        self.directory = directory
        self.width = width
        self.height = height
        self.minimumMs = minimumMs
    }

    /// La repetición que se prepara o que está al aire, o nil.
    public var activeId: Int64? {
        lock.lock(); defer { lock.unlock() }
        return current?.id ?? preparing
    }

    /// Prepara `[fromRigMs, toRigMs)` (recortado a lo que guarda el anillo) y la deja lista para
    /// entrar en el programa a los `leadMs` de `now()`, que es el reloj del soporte del maestro.
    /// Devuelve lo que se repite y cuándo entra; lanza si no se puede.
    public func prepare(
        id: Int64, fromRigMs: Int64, toRigMs: Int64, leadMs: Int64, now: () -> Int64
    ) async throws -> Armed {
        lock.lock()
        guard current == nil, preparing == nil else {
            lock.unlock()
            throw ReplayError.busy
        }
        preparing = id
        lock.unlock()
        defer {
            lock.lock()
            if preparing == id { preparing = nil }
            cancelled.remove(id)
            lock.unlock()
        }
        let tramo: ProgramRing.Clip
        do {
            tramo = try ring.clip(fromRigMs: fromRigMs, toRigMs: toRigMs, minimumMs: minimumMs)
        } catch let error as ProgramRing.RingError {
            throw ReplayError.ring(error)
        }
        let url = directory.appendingPathComponent("replay-\(id).mov")
        try? FileManager.default.removeItem(at: url)
        let jugador: ProgramVideoPlayer
        let cut: Int64
        do {
            try await ReplayClipWriter.write(
                tramo.frames, to: url, lastDurationNs: ring.frameDurationMs * ProgramRing.Clip.nsPerMs
            )
            // El corte se fija antes de abrir: lo que tarde en abrirse sale del margen, no del
            // tramo.
            cut = now() + leadMs
            jugador = try await ProgramVideoPlayer.open(
                url: url, id: id, startRigMs: Double(cut - tramo.skipMs), width: width, height: height,
                fromMs: Double(tramo.skipMs)
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ReplayError.clip("\(error)")
        }
        lock.lock()
        if cancelled.contains(id) {
            lock.unlock()
            jugador.stop()
            try? FileManager.default.removeItem(at: url)
            throw ReplayError.cancelled
        }
        current = Playing(id: id, player: jugador, url: url, cutRigMs: cut,
                          endRigMs: cut + (tramo.toRigMs - tramo.fromRigMs))
        lock.unlock()
        jugador.start()
        return Armed(id: id, fromRigMs: tramo.fromRigMs, toRigMs: tramo.toRigMs, cutRigMs: cut)
    }

    /// Vuelve al directo en el instante `cutRigMs` del programa (o en cuanto entre, si es
    /// antes). Si aún se prepara, no saldrá.
    public func stop(id: Int64, atRigMs cutRigMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if var c = current, c.id == id {
            c.endRigMs = min(c.endRigMs, max(cutRigMs, c.cutRigMs))
            current = c
        } else if preparing == id {
            cancelled.insert(id)
        }
    }

    /// El fotograma de la repetición que tapa las cámaras en el instante `t` del programa, o
    /// nil si en `t` va el directo. Al pasar su final la suelta.
    public func frame(atRigMs t: Int64) -> CVPixelBuffer? {
        lock.lock()
        guard let c = current, t >= c.cutRigMs else {
            lock.unlock()
            return nil
        }
        if t >= c.endRigMs || c.player.isFinished(atRigMs: Double(t)) {
            current = nil
            lock.unlock()
            soltar(c)
            return nil
        }
        framesServed += 1
        lock.unlock()
        return c.player.frame(atRigMs: Double(t))
    }

    /// Al acabar la pasada: vacía el anillo y quita la repetición, si la hay.
    public func reset() {
        ring.reset()
        lock.lock()
        let c = current
        current = nil
        if let id = preparing { cancelled.insert(id) }
        lock.unlock()
        if let c { soltar(c) }
    }

    private func soltar(_ c: Playing) {
        c.player.stop()
        try? FileManager.default.removeItem(at: c.url)
    }
}
