// El compás propio del programa (IOS-84), lógica pura.
//
// El programa sale a 30 fps de la rejilla del reloj del soporte, no de la captura: si una
// cámara se para, el programa sigue. En cada instante se elige la fuente por este orden:
// las dos lentes; solo el maestro; solo la parte del esclavo; y sin ninguna, se repite el
// último fotograma hasta PROGRAM_HOLD_MS y después SIN SEÑAL con el marcador.

import Foundation

public enum ProgramClockConstants {
    /// Lo que se repite el último fotograma antes de pasar a SIN SEÑAL, en ms. Medio
    /// segundo: tapa un hipo de la cámara sin congelar la imagen a la vista. Decisión de
    /// IOS-84 (no estaba en la referencia); anotada en PROGRESS.
    public static let holdMs: Int64 = 500

    /// El fotograma propio deja de valer para el programa si es más viejo que esto, en
    /// ms: dos fotogramas a 30 fps.
    public static let masterFrameStaleMs: Int64 = 67
}

public enum ProgramSource: String, Sendable, CaseIterable {
    case twoLens, masterOnly, slaveOnly, hold, noSignal
}

public struct ProgramClock: Sendable {
    public let frameDurationMs: Double

    public init(frameDurationMs: Double = 1000.0 / 30.0) {
        self.frameDurationMs = frameDurationMs
    }

    /// El instante de la rejilla más reciente que no pasa de `rigMs`.
    /// (Con un épsilon: 1000 / 33,33… da 29,9999… en coma flotante y el instante 1000
    /// tiene que ser el 30.)
    public func gridInstant(atOrBefore rigMs: Int64) -> Int64 {
        let k = (Double(rigMs) / frameDurationMs + 1e-9).rounded(.down)
        return Int64((k * frameDurationMs).rounded())
    }

    /// La fuente del instante: `masterFrame` y `slavePart` dicen si hay fotograma propio y
    /// parte del esclavo para él; `lastRealFrameMs`, cuándo salió el último fotograma con
    /// imagen de verdad.
    public static func choose(
        masterFrame: Bool, slavePart: Bool, instantMs: Int64, lastRealFrameMs: Int64?
    ) -> ProgramSource {
        switch (masterFrame, slavePart) {
        case (true, true): return .twoLens
        case (true, false): return .masterOnly
        case (false, true): return .slaveOnly
        case (false, false):
            if let ultimo = lastRealFrameMs, instantMs - ultimo <= ProgramClockConstants.holdMs {
                return .hold
            }
            return .noSignal
        }
    }
}

/// Cuántos instantes salieron de cada fuente y la última, para la telemetría y
/// /api/v1/rig/status.
public struct ProgramSourceStats: Equatable, Sendable {
    public private(set) var counts: [String: Int] = [:]
    public private(set) var current: ProgramSource?
    public private(set) var lastRealFrameMs: Int64?

    public init() {}

    public mutating func record(_ s: ProgramSource, instantMs: Int64) {
        counts[s.rawValue, default: 0] += 1
        current = s
        if s != .hold, s != .noSignal { lastRealFrameMs = instantMs }
    }
}
