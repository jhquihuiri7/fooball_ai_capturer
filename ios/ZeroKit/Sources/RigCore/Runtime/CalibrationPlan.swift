// La pareja de fotogramas sincronizados para calibrar, lógica pura (IOS-70).
//
// El maestro elige N instantes de destino en el reloj del soporte, espaciados
// RIG_CALIB_PAIR_SPACING_MS y a RIG_CALIB_LEAD_MS de ahora, y los manda al esclavo. Cada
// móvil toma de su anillo, para cada destino, el fotograma más cercano si está a
// ≤RIG_PAIR_TOLERANCE (16 ms); si no, el primero de después. Así las dos mitades de una
// pareja son del mismo instante, y la calibración no cose un balón en dos sitios.

import Foundation

public enum CalibrationPlan {
    /// Los instantes de destino, en ms del soporte.
    public static func targets(
        nowRigMs: Int64,
        count: Int = RigConstants.rigCalibPairCount,
        spacingMs: Int = RigConstants.rigCalibPairSpacingMs,
        leadMs: Int = RigConstants.rigCalibLeadMs
    ) -> [Int64] {
        (0..<max(0, count)).map { nowRigMs + Int64(leadMs) + Int64($0 * spacingMs) }
    }

    /// Tolerancia de la pareja, en ms (la de `RIG_PAIR_TOLERANCE_NS`).
    public static let toleranceMs = Int64(RigConstants.rigPairToleranceNs / 1_000_000)

    /// El fotograma que se usa para `target`, de entre los instantes disponibles: el más
    /// cercano a ≤`toleranceMs`; si no hay, el primero posterior. nil si todavía no hay
    /// ninguno a la altura del destino (hay que esperar).
    public static func choose(available: [Int64], target: Int64, toleranceMs: Int64 = toleranceMs) -> Int64? {
        let cercano = available.min { abs($0 - target) < abs($1 - target) }
        if let cercano, abs(cercano - target) <= toleranceMs {
            return cercano
        }
        return available.filter { $0 > target }.min()
    }
}
