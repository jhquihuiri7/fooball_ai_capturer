// El anillo del programa (IOS-118, ADR 0034): lo que sale del codificador del programa, tal
// cual, para repetirlo.
//
// Guarda los fotogramas H.264 ya codificados (los mismos `EncodedFrame` que van al SRT y a la
// copia .mov, sin copiarlos) durante `replay.ring_s` y como mucho `replay.ring_max_mb`. Empieza
// siempre en un IDR: lo que hay antes del primero no se puede decodificar. Si cambia la
// descripción del formato (iOS rehízo la sesión del codificador), lo de antes se tira: un
// tramo tiene que leerse con un solo formato.
//
// El instante de cada fotograma es el del programa, `ptsNs`: el reloj del soporte en el que
// el maestro compone (ADR 0023 §4), el mismo con el que el mando pone las marcas.

import CoreMedia
import Foundation
import RigCore

public final class ProgramRing {
    /// Lo que hay guardado: del primer IDR al último fotograma, en ms del programa.
    public struct Span: Equatable, Sendable {
        public let oldestRigMs: Int64
        public let newestRigMs: Int64
    }

    /// Un tramo listo para escribir: los fotogramas desde el IDR anterior a `fromRigMs`, y lo que
    /// se verá de verdad, `[fromRigMs, toRigMs)`.
    public struct Clip {
        public let frames: [EncodedFrame]
        public let fromRigMs: Int64
        public let toRigMs: Int64
        /// Ms del primer fotograma del tramo (el IDR) a `fromRigMs`: lo que el lector se salta.
        public var skipMs: Int64 { fromRigMs - (frames.first.map { $0.ptsNs / Self.nsPerMs } ?? fromRigMs) }

        static let nsPerMs: Int64 = 1_000_000
    }

    public enum RingError: Error, Equatable {
        /// No hay programa: el anillo está vacío.
        case empty
        /// Lo que se pide ya no está, o todavía no ha pasado.
        case notInMemory
        /// Lo que queda del tramo dentro de lo guardado no llega al mínimo.
        case tooShort
    }

    public let maxDurationMs: Int64
    public let maxBytes: Int
    /// La duración de un fotograma del programa, en ms: cierra el tramo tras el último.
    public let frameDurationMs: Int64

    private let lock = NSLock()
    /// `frames[head...]` son los guardados; lo de delante ya salió y se compacta de vez en cuando.
    private var frames: [EncodedFrame] = []
    private var head = 0
    private var bytes = 0
    private var format: CMFormatDescription?

    /// Los que salen por delante antes de mover el array (unos 8 s a 30 fps): hasta entonces
    /// siguen en memoria, así que es también lo que el anillo retiene de más.
    static let compactEvery = 256
    /// Bytes por MB (2^20): el tope del anillo viene en MB. Público porque lo usa el valor
    /// por defecto de `init`.
    public static let bytesPerMb = 1 << 20

    public init(
        maxDurationMs: Int64 = Int64(OverlaySpec.replay["ring_s"] ?? 0) * 1000,
        maxBytes: Int = (OverlaySpec.replay["ring_max_mb"] ?? 0) * ProgramRing.bytesPerMb,
        frameDurationMs: Int64 = Int64(1000 / OverlaySpec.programFps)
    ) {
        self.maxDurationMs = maxDurationMs
        self.maxBytes = maxBytes
        self.frameDurationMs = frameDurationMs
    }

    /// Los fotogramas guardados ahora.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count - head
    }

    /// Los bytes guardados ahora.
    public var storedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    /// Del primer IDR al último fotograma; nil sin nada.
    public var span: Span? {
        lock.lock(); defer { lock.unlock() }
        guard head < frames.count, let ultimo = frames.last else { return nil }
        return Span(oldestRigMs: Self.ms(frames[head]), newestRigMs: Self.ms(ultimo))
    }

    /// Un fotograma recién codificado. Sin formato no entra (no se podría escribir).
    public func append(_ f: EncodedFrame) {
        guard let fd = f.formatDescription else { return }
        lock.lock()
        defer { lock.unlock() }
        if let actual = format, !CMFormatDescriptionEqual(actual, otherFormatDescription: fd) {
            vaciar()
        }
        if head == frames.count, !f.isKeyframe { return }
        format = fd
        frames.append(f)
        bytes += f.data.count
        recortar()
    }

    /// Lo vacía: al acabar la pasada, o con otro programa.
    public func reset() {
        lock.lock()
        vaciar()
        lock.unlock()
    }

    /// El tramo `[fromRigMs, toRigMs)`, recortado a lo guardado. Lanza si no hay nada, si el
    /// tramo cae fuera o si lo que queda dura menos de `minimumMs`.
    public func clip(fromRigMs: Int64, toRigMs: Int64, minimumMs: Int64) throws -> Clip {
        lock.lock()
        defer { lock.unlock() }
        guard head < frames.count, let ultimo = frames.last else { throw RingError.empty }
        let desde = max(fromRigMs, Self.ms(frames[head]))
        let hasta = min(toRigMs, Self.ms(ultimo) + frameDurationMs)
        guard hasta > desde else { throw RingError.notInMemory }
        guard hasta - desde >= minimumMs else { throw RingError.tooShort }
        // El último IDR que no pasa de `desde`; el primero guardado lo es siempre.
        var inicio = head
        for i in head..<frames.count {
            let ms = Self.ms(frames[i])
            if ms > desde { break }
            if frames[i].isKeyframe { inicio = i }
        }
        var fin = inicio
        while fin < frames.count, Self.ms(frames[fin]) < hasta { fin += 1 }
        return Clip(frames: Array(frames[inicio..<fin]), fromRigMs: desde, toRigMs: hasta)
    }

    // MARK: - Dentro (con `lock`)

    private func vaciar() {
        frames.removeAll(keepingCapacity: true)
        head = 0
        bytes = 0
        format = nil
    }

    /// Saca por delante lo que pasa de los topes y lo que quede antes del siguiente IDR.
    private func recortar() {
        guard let nuevo = frames.last.map(Self.ms) else { return }
        while head < frames.count - 1, nuevo - Self.ms(frames[head]) > maxDurationMs || bytes > maxBytes {
            sacar()
        }
        while head < frames.count, !frames[head].isKeyframe {
            sacar()
        }
        if head >= Self.compactEvery {
            frames.removeFirst(head)
            head = 0
        }
    }

    private func sacar() {
        bytes -= frames[head].data.count
        head += 1
    }

    private static func ms(_ f: EncodedFrame) -> Int64 { f.ptsNs / Clip.nsPerMs }
}
