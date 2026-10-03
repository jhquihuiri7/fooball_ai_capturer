// Constantes del pipeline de captura (IOS-04), con unidades y por qué.
//
// La regla es la del servidor (CLAUDE.md §2 de football-ai): ninguna constante de
// comportamiento incrustada en una expresión.

import Foundation

public enum PipelineConstants {
    /// Huecos del anillo de fotogramas propio (`FRAME_RING_SLOTS` en el plan).
    ///
    /// 4 fotogramas NV12 4K son 4 × 12,4 MB ≈ 50 MB: suficiente para que el detector
    /// (7,5 Hz: uno de cada cuatro) y el render encuentren su fotograma sin que la
    /// cámara espere, y poco para un móvil de 8 GB vigilado por el jetsam. La cámara
    /// NUNCA retiene más de un búfer suyo (IOS-09): este anillo es la copia propia.
    public static let frameRingSlots = 4

    /// Fotogramas que el pool de píxeles mantiene listos por encima del anillo.
    ///
    /// Es el margen para el que está «en vuelo» hacia el codificador o la vista previa
    /// mientras el anillo ya reutilizó su hueco.
    public static let pixelPoolHeadroom = 2
}
