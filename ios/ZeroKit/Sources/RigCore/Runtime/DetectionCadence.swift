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
