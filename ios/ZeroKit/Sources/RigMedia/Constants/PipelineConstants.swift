// Constantes del pipeline de captura (IOS-04), con unidades y por qué.
//
// La regla es la del servidor (CLAUDE.md §2 de football-ai): ninguna constante de
// comportamiento incrustada en una expresión.

import Foundation

public enum PipelineConstants {
    /// Huecos del anillo de fotogramas propio (`FRAME_RING_SLOTS` en el plan).
    ///
    /// 6 fotogramas NV12 4K son 6 × 12,4 MB ≈ 75 MB. El maestro pide su fotograma de
    /// hace `LinkConstants.partMaxWaitMs` (130 ms, 4 fotogramas a 30 fps) más el jitter
    /// de la cámara, y el detector (7,5 Hz) retiene uno: con 4 huecos, el de 130 ms ya
    /// había salido del anillo en 175 de 36 000 fotogramas (2026-10-07). Sigue siendo
    /// poco para un móvil de 8 GB vigilado por el jetsam. La cámara NUNCA retiene más de
    /// un búfer suyo (IOS-09): este anillo es la copia propia.
    public static let frameRingSlots = 6

    /// Fotogramas que el pool de píxeles mantiene listos por encima del anillo.
    ///
    /// Es el margen para el que está «en vuelo» hacia el codificador o la vista previa
    /// mientras el anillo ya reutilizó su hueco.
    public static let pixelPoolHeadroom = 2
}
