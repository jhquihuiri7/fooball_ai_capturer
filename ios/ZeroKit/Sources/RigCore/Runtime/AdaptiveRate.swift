// El bitrate del programa según lo que deja pasar la red hasta el VPS (IOS-56).
//
// Es AdaptiveBitRate de StreamPublisher.swift (el directo al pod, ADR 0012) sin HaishinKit:
// allí la señal era `publishInsufficientBWOccured` (la cola del socket creció tres
// segundos seguidos) y lo medido, los bytes que salieron. Aquí las dos cosas salen de SRT
// una vez por segundo: el búfer de envío por encima del umbral, o un descarte en la cola
// del publicador, es congestión; `mbpsSendRate` es lo que salió.
//
// - Ante congestión se baja a lo que salió con margen (`backoff`), nunca por encima de lo
//   que había ni por debajo del mínimo.
// - Sin congestión, se sube un escalón (un décimo del máximo) tras `raiseAfterSamples`
//   muestras seguidas, hasta el techo vigente.
// - El techo vigente es el de fábrica por el factor de la escalera de degradación
//   (DegradationLadder, L3 ×0,6): si baja por debajo del bitrate actual, se aplica ya.
// - Al reconectar se conserva el bitrate: es lo último que se sabe que cabía. Salvo lo
//   bajado en los segundos en que no salió nada: eso era el corte que acabó en la
//   reconexión (el otro lado dejó de confirmar), no falta de ancho de banda, y se vuelve
//   al de antes. Medido en el Mac con MediaMTX caído 2 s: sin esto, de 6 a 1 Mbit/s y dos
//   minutos para volver a subir.

import Foundation

public struct AdaptiveRate: Sendable {
    /// Bits por segundo por debajo de los que no se baja: un 1080p de fútbol a menos es
    /// papilla, y mejor que se note el corte. El mismo suelo que el del pod.
    public static let minimumBps = 1_000_000

    /// Muestras seguidas sin congestión antes de subir un escalón. Con una muestra por
    /// segundo son 15 s: subir es barato de deshacer, pero despacio converge en vez de
    /// oscilar, y el soporte comparte el enlace con el túnel (ADR 0012, decisión 7).
    public static let raiseAfterSamples = 15

    /// Fracción de lo medido a la que se baja: lo que salió menos un margen, para que el
    /// búfer se vacíe y no solo deje de crecer.
    public static let backoff = 0.8

    /// El escalón de subida, como fracción del máximo de fábrica.
    public static let raiseStepFraction = 0.1

    /// El techo de fábrica, en bits por segundo (PROGRAM_VIDEO_BITRATE_BPS).
    public let maximumBps: Int
    /// El bitrate que se le pide al codificador ahora.
    public private(set) var currentBps: Int
    private var stableSamples = 0
    /// El bitrate de antes de la primera muestra congestionada en la que no salió nada.
    private var bpsBeforeStall: Int?

    public init(maximumBps: Int, startBps: Int? = nil) {
        self.maximumBps = max(maximumBps, Self.minimumBps)
        currentBps = min(max(startBps ?? maximumBps, Self.minimumBps), self.maximumBps)
    }

    /// A qué bajar cuando hay congestión: lo que salió con margen, nunca más de lo que
    /// había y nunca por debajo del mínimo. Con `measured` 0 (no salió nada), a la mitad.
    public static func next(current: Int, measured: Int) -> Int {
        let target = measured > 0 ? Int(Double(measured) * backoff) : current / 2
        return max(min(current, target), minimumBps)
    }

    /// Una muestra (una por segundo). `measuredBps` es lo que salió en ese segundo y
    /// `ceilingBps` el techo vigente (la escalera); `nil` es el de fábrica. Devuelve el
    /// bitrate nuevo si cambia.
    public mutating func sample(congested: Bool, measuredBps: Int, ceilingBps: Int? = nil) -> Int? {
        let top = max(min(maximumBps, ceilingBps ?? maximumBps), Self.minimumBps)
        let antes = currentBps
        if congested {
            stableSamples = 0
            if measuredBps > 0 {
                bpsBeforeStall = nil
            } else if bpsBeforeStall == nil {
                bpsBeforeStall = currentBps
            }
            currentBps = Self.next(current: currentBps, measured: measuredBps)
        } else {
            if measuredBps > 0 { bpsBeforeStall = nil }
            stableSamples += 1
            if currentBps < top, stableSamples >= Self.raiseAfterSamples {
                stableSamples = 0
                currentBps = min(currentBps + Int(Double(maximumBps) * Self.raiseStepFraction), top)
            }
        }
        currentBps = min(currentBps, top)
        return currentBps == antes ? nil : currentBps
    }

    /// Reconexión: la cuenta para subir empieza de nuevo y el bitrate se queda, salvo lo
    /// bajado mientras no salía nada, que se deshace (hasta el techo vigente). Devuelve el
    /// bitrate nuevo si cambia.
    @discardableResult
    public mutating func reset(ceilingBps: Int? = nil) -> Int? {
        stableSamples = 0
        guard let antes = bpsBeforeStall else { return nil }
        bpsBeforeStall = nil
        let top = max(min(maximumBps, ceilingBps ?? maximumBps), Self.minimumBps)
        let nuevo = min(max(currentBps, antes), top)
        guard nuevo != currentBps else { return nil }
        currentBps = nuevo
        return nuevo
    }
}
