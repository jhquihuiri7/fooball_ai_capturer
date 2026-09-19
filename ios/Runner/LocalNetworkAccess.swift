// El permiso de red local de iOS, pedido al preparar la cámara y no en mitad del partido.
//
// iOS no tiene una llamada para pedirlo: el aviso salta la primera vez que la app toca
// la red local. Si eso pasa cuando ya se está emitiendo, el operador no lo ve, los
// paquetes se tiran en silencio y el stream no sale sin dar ningún error. Así que se
// provoca aquí, junto al permiso de cámara, con el truco estándar: anunciar un servicio
// Bonjour propio y buscarlo. Solo se encuentra a sí mismo si el permiso está concedido;
// si está denegado, el buscador falla con `PolicyDenied`.

import Foundation
import Network

enum LocalNetworkAccess {
    /// Tipo Bonjour propio, solo para esta comprobación. Está en `NSBonjourServices`.
    /// No es el del enlace entre móviles a propósito: si lo fuera, el derecho vería este
    /// anuncio de un instante como si fuera el izquierdo y lo invitaría.
    static let serviceType = "_footballai-lan._tcp"

    /// Código DNS-SD `kDNSServiceErr_PolicyDenied`: el usuario dijo que no.
    private static let policyDenied: DNSServiceErrorType = -65570

    /// Segundos de espera máxima. El aviso del sistema es modal: si el operador no
    /// contesta, se devuelve `false` y la pantalla dice cómo activarlo en Ajustes.
    private static let timeoutSeconds: Double = 20

    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            // Todo en la cola principal, así el cierre se ejecuta una sola vez sin cerrojo.
            var finished = false
            var listener: NWListener?
            var browser: NWBrowser?
            let finish: (Bool) -> Void = { allowed in
                guard !finished else { return }
                finished = true
                listener?.cancel()
                browser?.cancel()
                continuation.resume(returning: allowed)
            }

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            do {
                listener = try NWListener(using: parameters)
            } catch {
                finish(false)
                return
            }
            listener?.service = NWListener.Service(name: UUID().uuidString, type: serviceType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { state in
                NSLog("[red local] anuncio: %@", String(describing: state))
                if case .failed = state { finish(false) }
            }

            browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
            browser?.browseResultsChangedHandler = { results, _ in
                NSLog("[red local] servicios vistos: %d", results.count)
                if !results.isEmpty { finish(true) }
            }
            browser?.stateUpdateHandler = { state in
                NSLog("[red local] busqueda: %@", String(describing: state))
                switch state {
                case let .waiting(error), let .failed(error):
                    if case let .dns(code) = error, code == policyDenied { finish(false) }
                default:
                    break
                }
            }

            listener?.start(queue: .main)
            browser?.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                if !finished { NSLog("[red local] sin respuesta en %.0f s", timeoutSeconds) }
                finish(false)
            }
        }
    }
}
