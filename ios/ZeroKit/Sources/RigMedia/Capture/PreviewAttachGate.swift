// Cuándo la capa de vista previa toma la sesión de captura (2026-10-15).
//
// El iPhone 17 murió emitiendo en «Una cámara» con Zero al fondo: FRONTBOARD 0x8BADF00D,
// «Failed to terminate gracefully after 5.0s» (Runner-2026-10-15-183257.ips). El hilo
// principal estaba en `AVCaptureVideoPreviewLayer(session:)`: AVFoundation quita la capa
// anterior de la sesión y rehace el grafo de captura ahí mismo (`_removeAllPreviewLayers`
// → `commitConfiguration` → `_buildAndRunGraph`), y con la cámara interrumpida por el
// fondo esa espera no vuelve. La regla desde entonces: una capa para toda la vida de la
// sesión, y la sesión se le pone en la cola de captura solo cuando la app está delante y
// la cámara no está interrumpida. Esta puerta es la que lo decide; `CaptureEngine` la
// consulta en su cola y hace lo que diga.

import Foundation

/// Decide cuándo la capa de vista previa toma la sesión. Lógica pura, sin AVFoundation.
public struct PreviewAttachGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Ponerle la sesión ahora, en la cola de captura. Se da una sola vez.
        case attach
        /// Todavía no, y por qué (para el log y los `app_events` del latido).
        case wait(String)
        /// Nada que hacer: nadie la ha pedido, o ya la tiene.
        case nothing
    }

    /// Flutter montó la vista y la capa quiere la sesión.
    public private(set) var requested = false
    /// Ya la tiene. No se vuelve a poner: la capa es la misma mientras viva la sesión.
    public private(set) var attached = false
    /// La app está al fondo (`didEnterBackground` … `willEnterForeground`).
    public private(set) var appInBackground: Bool
    /// La sesión está interrumpida (`AVCaptureSession.isInterrupted`): el fondo, una
    /// llamada, otra app con la cámara.
    public private(set) var sessionInterrupted = false

    public static let backgroundReason = "la app está al fondo"
    public static let interruptedReason = "la cámara está interrumpida"

    public init(appInBackground: Bool = false) {
        self.appInBackground = appInBackground
    }

    /// La capa pide la sesión (se montó la vista de plataforma).
    public mutating func request() -> Decision {
        requested = true
        return evaluate()
    }

    /// La app entró al fondo o vuelve de él.
    public mutating func app(inBackground: Bool) -> Decision {
        appInBackground = inBackground
        return evaluate()
    }

    /// La sesión se interrumpió o volvió; `interrupted` es su estado real ahora mismo.
    public mutating func session(interrupted: Bool) -> Decision {
        sessionInterrupted = interrupted
        return evaluate()
    }

    private mutating func evaluate() -> Decision {
        guard requested, !attached else { return .nothing }
        if appInBackground { return .wait(Self.backgroundReason) }
        if sessionInterrupted { return .wait(Self.interruptedReason) }
        attached = true
        return .attach
    }
}
