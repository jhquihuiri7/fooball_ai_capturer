// El director de guion de SPK-04 (el render repartido), lógica pura.
//
// Un barrido en yaw que cruza la costura cada `seamCrossEveryS` y un zoom en triángulo de
// `hfovMinDeg` a `hfovMaxDeg`, los dos en función SOLO del instante en el reloj del
// soporte (sin instante de arranque): la referencia de Python (REF-41) lo recalcula igual
// con el `rigMs` de cada fotograma del programa, la costura y el pitch del rig.json.
//
//   yaw(t)  = costura + A · sin(2π · (t mod P) / P),   P = 2 · seamCrossEveryS
//   hfov(t) = min + (max − min) · tri((t mod Z) / Z),  tri(x) = 1 − |2x − 1|
//
// La costura es la media de los yaw de las dos cámaras y el pitch, la media de sus
// pitch (como el barrido de siempre del banco). Con A = 35° y el zoom cerrado (hfov
// < 68°) el encuadre llega a caer entero en una lente a cada lado: son los planos de una
// sola lente que pide SPK-05 para el VMAF por mitades.

import Foundation

public struct Spk04Script: Sendable {
    /// Cada cuánto cruza la costura el barrido, en s (tarjeta SPK-04).
    public static let seamCrossEveryS = 20.0
    /// Amplitud del barrido a cada lado de la costura, en grados. Con las cámaras a ±42° y
    /// 106° de HFOV, el borde del encuadre más abierto (35 + 41,5°) sigue dentro de la
    /// cámara (42 + 53°).
    public static let sweepAmplitudeDeg = 35.0
    /// El zoom, de HFOV en grados (tarjeta SPK-04: de 40° a 83°).
    public static let hfovMinDeg = 40.0
    public static let hfovMaxDeg = 83.0
    /// El periodo del zoom (ida y vuelta), en s. No es múltiplo de los 40 s del barrido:
    /// cada 120 s se repiten todas las combinaciones de zoom y lado.
    public static let zoomPeriodS = 60.0

    static let msPerS = 1000.0

    public let seamYawRad: Double
    public let pitchRad: Double

    public init(seamYawRad: Double, pitchRad: Double) {
        self.seamYawRad = seamYawRad
        self.pitchRad = pitchRad
    }

    /// La costura y el pitch del soporte calibrado.
    public init(rig: RigModel) {
        self.init(
            seamYawRad: (rig.camera(.left).pose.yawRad + rig.camera(.right).pose.yawRad) / 2,
            pitchRad: (rig.camera(.left).pose.pitchRad + rig.camera(.right).pose.pitchRad) / 2
        )
    }

    /// Yaw y HFOV del encuadre en el instante `rigMs` del reloj del soporte.
    public func pose(atRigMs rigMs: Int64) -> (yawRad: Double, hfovRad: Double) {
        let barridoMs = Int64(2 * Self.seamCrossEveryS * Self.msPerS)
        let zoomMs = Int64(Self.zoomPeriodS * Self.msPerS)
        // El módulo en enteros: con rigMs de días, el seno de un Double grande pierde fase.
        let fase = Double(Self.positiveModulo(rigMs, barridoMs)) / Double(barridoMs)
        let faseZoom = Double(Self.positiveModulo(rigMs, zoomMs)) / Double(zoomMs)
        let yaw = seamYawRad + Self.sweepAmplitudeDeg * .pi / 180 * sin(2 * .pi * fase)
        let triangulo = 1 - abs(2 * faseZoom - 1)
        let hfov = Self.hfovMinDeg + (Self.hfovMaxDeg - Self.hfovMinDeg) * triangulo
        return (yaw, hfov * .pi / 180)
    }

    /// Los parámetros del guion, para el informe del banco (la referencia los necesita).
    public static var parameters: [String: Double] {
        ["seam_cross_every_s": seamCrossEveryS, "sweep_amplitude_deg": sweepAmplitudeDeg,
         "hfov_min_deg": hfovMinDeg, "hfov_max_deg": hfovMaxDeg, "zoom_period_s": zoomPeriodS]
    }

    private static func positiveModulo(_ a: Int64, _ m: Int64) -> Int64 {
        let r = a % m
        return r < 0 ? r + m : r
    }
}
