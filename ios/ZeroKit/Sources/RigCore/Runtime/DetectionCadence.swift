// La cadencia del detector anclada al reloj del soporte (IOS-25), lógica pura.
//
// Los dos móviles detectan en los mismos instantes del soporte, t_k = k / hz, sin
// mandarse un mensaje: cada uno toma el fotograma de su anillo más cercano a t_k. Como
// la fase de las dos cámaras está a ≤5 ms (ADR 0012), las detecciones de las dos son del
// mismo instante y la fusión las empareja por rigMs (IOS-32).

import Foundation

public struct DetectionCadence: Equatable, Sendable {
    /// Detecciones por segundo (PLAYER_TARGET_HZ, o lo que mande el maestro).
    public let hz: Double

    public init(hz: Double = DetectionSpec.playerTargetHz) {
        precondition(hz > 0, "la cadencia tiene que ser positiva")
        self.hz = hz
    }

    public var periodMs: Double { 1000 / hz }

    /// El índice k del instante de la rejilla más cercano a `rigMs`.
    public func index(nearest rigMs: Int64) -> Int64 {
        Int64((Double(rigMs) / periodMs).rounded())
    }

    /// El instante t_k, en ms del soporte (redondeado al ms).
    public func instant(_ k: Int64) -> Int64 {
        Int64((Double(k) * periodMs).rounded())
    }

    /// El primer instante de la rejilla estrictamente posterior a `rigMs`.
    public func next(after rigMs: Int64) -> Int64 {
        var k = Int64((Double(rigMs) / periodMs).rounded(.down))
        while instant(k) <= rigMs { k += 1 }
        return instant(k)
    }
}

/// La cadencia aplicada tic a tic en el banco split y EMITIR (IOS-25 con la escalera,
/// IOS-06): qué instante t_k de la rejilla toca detectar, viendo el último fotograma del
/// anillo. Es la regla de PlayerDetectionStage —el fotograma de después del instante es el
/// que permite elegir el más cercano— para quien no recibe cada fotograma sino un tic.
///
/// Los dos móviles detectan así en los mismos t_k del soporte y el director del maestro los
/// empareja con desfase cero. Cambiar la cadencia (la escalera) empieza la rejilla nueva; 0
/// la apaga (L2).
public struct DetectionGate: Sendable {
    /// Medio fotograma, redondeado hacia arriba: lo más lejos que puede quedar del instante
    /// el fotograma que se usa.
    public let halfFrameMs: Int64
    /// La cadencia vigente, en Hz; 0 con la IA apagada.
    public private(set) var hz: Double = 0
    /// Instantes que se saltaron porque el tic llegó más de un periodo tarde.
    public private(set) var skipped = 0
    private var cadence: DetectionCadence?
    private var nextTarget: Int64?

    public init(frameDurationMs: Double) {
        halfFrameMs = Int64((frameDurationMs / 2).rounded(.up))
    }

    /// La cadencia que manda la escalera. Solo cambia algo si es otra.
    public mutating func set(hz nuevo: Double) {
        guard nuevo != hz else { return }
        hz = nuevo
        cadence = nuevo > 0 ? DetectionCadence(hz: nuevo) : nil
        nextTarget = nil
    }

    /// El instante que toca detectar ahora, con el fotograma más nuevo del anillo en
    /// `latestRigMs`; nil si aún no toca o si la IA está apagada. Quien lo usa toma del
    /// anillo el fotograma más cercano a él, a ≤ `halfFrameMs`.
    public mutating func due(latestRigMs: Int64) -> Int64? {
        guard let cadence else { return nil }
        let objetivo = nextTarget ?? cadence.next(after: latestRigMs - halfFrameMs)
        guard latestRigMs >= objetivo else {
            nextTarget = objetivo
            return nil
        }
        // Un tic más de un periodo tarde: al instante más reciente; los de en medio caducaron
        // (detectarlos ahora retrasaría el siguiente) y se cuentan.
        let reciente = cadence.instant(Int64((Double(latestRigMs) / cadence.periodMs).rounded(.down)))
        var elegido = objetivo
        if reciente > objetivo {
            skipped += Int(cadence.index(nearest: reciente) - cadence.index(nearest: objetivo))
            elegido = reciente
        }
        nextTarget = cadence.next(after: elegido)
        return elegido
    }
}
