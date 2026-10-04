// La vigilancia de la costura (IOS-72, anotación del ADR 0012).
//
// La mediana de `separationRad` de las detecciones fundidas del solape: con la
// calibración bien es paralaje y ruido, y una pose que se ha movido suma su error a
// todas las parejas. Por encima del umbral sugiere recalibrar; no cambia nada solo.

import Foundation

public final class SeamWatch {
    public let maxMedianRad: Double
    public let minSamples: Int

    private var ring: [Double]
    private var scratch: [Double]
    private var next = 0
    private var count = 0

    /// Los búferes se reservan aquí y no vuelven a crecer: el anillo y la copia que
    /// se ordena para la mediana.
    public init(
        maxMedianRad: Double = RigConstants.rigSeamWatchMaxMedianRad,
        window: Int = RigConstants.rigSeamWatchWindow,
        minSamples: Int = RigConstants.rigSeamWatchMinSamples
    ) {
        precondition(window > 0 && minSamples > 0 && minSamples <= window)
        self.maxMedianRad = maxMedianRad
        self.minSamples = minSamples
        ring = [Double](repeating: 0, count: window)
        scratch = [Double](repeating: 0, count: window)
    }

    /// Las parejas de un ciclo de detección. Solo cuentan las vistas por las dos
    /// cámaras: una sola no tiene separación que medir.
    public func observe(_ detections: [RigPlayerDetection]) {
        for d in detections where d.sides.count == 2 {
            ring[next] = d.separationRad
            next = (next + 1) % ring.count
            count = min(count + 1, ring.count)
        }
    }

    /// La mediana de lo que hay en la ventana, o `nil` con menos de `minSamples`.
    public var medianRad: Double? {
        guard count >= minSamples else { return nil }
        for i in 0..<count {
            scratch[i] = ring[i]
        }
        scratch[0..<count].sort()
        return count % 2 == 1
            ? scratch[count / 2]
            : (scratch[count / 2 - 1] + scratch[count / 2]) / 2
    }

    /// `true` cuando la costura se ha abierto lo bastante como para recalibrar.
    public var suggestsRecalibration: Bool {
        guard let medianRad else { return false }
        return medianRad > maxMedianRad
    }

    /// Vacía la ventana: tras recalibrar, lo anterior describe otro soporte.
    public func reset() {
        next = 0
        count = 0
    }
}
