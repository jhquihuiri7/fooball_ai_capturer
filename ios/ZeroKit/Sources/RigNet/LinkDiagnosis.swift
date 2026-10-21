// Por qué no hay enlace, dicho por el propio móvil (2026-10-15).
//
// En el plan B de la cancha (`bench/partido-20261015-0902`) el esclavo no enlazó en 10 min
// y nada decía por qué: la línea de tiempo del transporte solo iba en el informe final, que
// ese esclavo no escribió, y el latido no traía nada del enlace. Esto es lo que el latido y
// el informe cuentan ahora: qué hace la cita (publicar o buscar), si espera y por qué, qué
// ha visto, cuántas veces lo intentó y cómo cayó, y una frase que lo resume para leerla en
// la cancha.

import Foundation

public struct LinkDiagnosis: Equatable, Sendable {
    public enum Role: String, Sendable {
        /// El izquierdo: anuncia la cita y espera a que llegue el otro.
        case publishes = "publica"
        /// El derecho: busca la cita del otro y conecta.
        case searches = "busca"
    }

    public var role: Role
    /// El medio de la cita: «aware», «wifi», «ethernet»…
    public var medium: String
    public var state: LinkTransportState
    /// Por qué espera la cita de control (Wi-Fi Aware: «Network is down», sin emparejado…).
    public var waiting: String?
    /// Por qué se acabó la última cita sin ser un fallo (`publisherTimeout`…).
    public var lastRendezvousEnd: String?
    /// La última caída del control, con su motivo («sin respuesta en 10 s», «silencio…»).
    public var lastDrop: String?
    /// La cita de control, publicada o con la suscripción lista ahora mismo.
    public var rendezvousReady: Bool
    /// Anuncios del otro que ve ahora el que busca, por control y por medios.
    public var announcements: Int
    public var mediaAnnouncements: Int
    /// Citas de control abiertas desde el arranque (listeners o suscripciones).
    public var rendezvousOpened: Int
    /// Suscripciones cambiadas por el vigía porque no daban con nadie.
    public var resubscribes: Int
    /// Citas del que publica cambiadas por el vigía porque no llegaba nadie.
    public var republishes: Int
    /// Conexiones de control intentadas (el que busca) o llegadas (el que publica).
    public var controlAttempts: Int
    /// Segundos sin el control arriba (desde el arranque o la última caída); nil, arriba.
    public var withoutLinkS: Double?
    /// Bug B (2026-10-21): intentos de control seguidos que no han subido (el que busca),
    /// borrones hechos y, si hay uno en curso, los segundos que le quedan de pausa.
    public var failedAttempts: Int
    public var searchResets: Int
    public var quietS: Double?
    /// El último intento de control: a quién (o de quién, si llega) y su ruta al caer.
    public var lastAttempt: String?
    /// Lo que el transporte tiene abierto del par: conexiones de control y medios vivas,
    /// citas acabadas guardadas sin cancelar, citas canceladas que aún no han acabado y
    /// suscripciones (Bug B: nada del par anterior tiene que quedar retenido).
    public var liveConnections: Int
    public var retiredListeners: Int
    public var cancellingListeners: Int
    public var subscriptions: Int

    public init(
        role: Role, medium: String, state: LinkTransportState, waiting: String? = nil,
        lastRendezvousEnd: String? = nil, lastDrop: String? = nil, rendezvousReady: Bool = false,
        announcements: Int = 0, mediaAnnouncements: Int = 0, rendezvousOpened: Int = 0, resubscribes: Int = 0,
        republishes: Int = 0, controlAttempts: Int = 0, withoutLinkS: Double? = nil, failedAttempts: Int = 0,
        searchResets: Int = 0, quietS: Double? = nil, lastAttempt: String? = nil, liveConnections: Int = 0,
        retiredListeners: Int = 0, cancellingListeners: Int = 0, subscriptions: Int = 0
    ) {
        self.role = role
        self.medium = medium
        self.state = state
        self.waiting = waiting
        self.lastRendezvousEnd = lastRendezvousEnd
        self.lastDrop = lastDrop
        self.rendezvousReady = rendezvousReady
        self.announcements = announcements
        self.mediaAnnouncements = mediaAnnouncements
        self.rendezvousOpened = rendezvousOpened
        self.resubscribes = resubscribes
        self.republishes = republishes
        self.controlAttempts = controlAttempts
        self.withoutLinkS = withoutLinkS
        self.failedAttempts = failedAttempts
        self.searchResets = searchResets
        self.quietS = quietS
        self.lastAttempt = lastAttempt
        self.liveConnections = liveConnections
        self.retiredListeners = retiredListeners
        self.cancellingListeners = cancellingListeners
        self.subscriptions = subscriptions
    }

    /// Lo que se añade a «ve al otro pero no conecta» por Wi-Fi Aware: la espera que impone
    /// iOS tras reiniciar un móvil (`WiFiAwareTimings.staleDatapathS`).
    static let staleDatapathHint =
        ". Tras reiniciar un móvil, iOS tarda hasta 2,5 min en dejar enlazar, y hasta 4 min tras cambiar de lado: no cierres Zero"

    /// La frase para la cancha. Con la sesión, dice además si el control subió y la sesión no
    /// (rechazada por el secreto, un conflicto de maestros…).
    public func summary(session: RigLinkSession.State? = nil) -> String {
        let hace = withoutLinkS.map { String(format: " en %.0f s", $0) } ?? ""
        switch state {
        case .connected:
            guard let session else { return "enlace arriba" }
            if case .connected = session { return "enlace arriba" }
            return "control arriba, la sesión no: \(session.label)"
        case .idle:
            return "enlace parado"
        default:
            break
        }
        let citas = "\(rendezvousOpened) citas, \(role == .publishes ? republishes : resubscribes) rehechas"
        if role == .searches, let quietS {
            // El borrón (Bug B): se dice que es a propósito, cuánto le queda y por qué.
            let porque = lastDrop.map { "; la última caída: \($0)" } ?? ""
            return String(format: "en pausa %.0f s más para que Wi-Fi Aware suelte el enlace viejo (borrón %d%@)",
                          quietS.rounded(.up), searchResets, porque)
        }
        if let waiting {
            return role == .publishes ? "la cita no se publica: \(waiting) (\(citas))"
                : "la suscripción espera: \(waiting) (\(citas))"
        }
        if case let .failed(motivo) = state {
            return "la cita falló: \(motivo); se reintenta"
        }
        switch role {
        case .publishes:
            guard rendezvousReady else { return "la cita aún no está publicada\(hace)" }
            guard controlAttempts > 0 else { return "publicando; no ha llegado nadie\(hace) (\(citas))" }
            return "llegaron \(controlAttempts) conexiones y no sigue ninguna; la última: \(lastDrop ?? "?")"
        case .searches:
            if controlAttempts > 0 {
                // Por Wi-Fi Aware, tras reiniciar Zero en un móvil, iOS no deja enlazar en ~2 min
                // (FB23509767): se dice en la cancha para que nadie vuelva a cerrar la app, que
                // empezaría la espera otra vez.
                let espera = medium == "aware" && failedAttempts > 0 ? Self.staleDatapathHint : ""
                return "ve al otro pero no conecta: \(controlAttempts) intentos; el último: \(lastDrop ?? "en marcha")"
                    + espera
            }
            if announcements > 0 { return "ve al otro; conectando" }
            return "no ve al otro\(hace) (\(citas)\(rendezvousReady ? "" : ", la última sin estar lista"))"
        }
    }

    /// Para el latido y el informe, en JSON.
    public func report(session: RigLinkSession.State? = nil) -> [String: Any] {
        [
            "summary": summary(session: session),
            "role": role.rawValue,
            "medium": medium,
            "state": state.label,
            "session": session?.label ?? "",
            "waiting": waiting ?? "",
            "rendezvous_ready": rendezvousReady,
            "last_rendezvous_end": lastRendezvousEnd ?? "",
            "last_drop": lastDrop ?? "",
            "announcements": announcements,
            "media_announcements": mediaAnnouncements,
            "rendezvous_opened": rendezvousOpened,
            "resubscribes": resubscribes,
            "republishes": republishes,
            "control_attempts": controlAttempts,
            "without_link_s": withoutLinkS ?? -1,
            "failed_attempts": failedAttempts,
            "search_resets": searchResets,
            "quiet_s": quietS ?? -1,
            "last_attempt": lastAttempt ?? "",
            "live_connections": liveConnections,
            "retired_listeners": retiredListeners,
            "listeners_cancelling": cancellingListeners,
            "subscriptions": subscriptions,
        ]
    }
}

extension LinkTransportState {
    /// En palabras, para el latido.
    public var label: String {
        switch self {
        case .idle: "parado"
        case .listening: "escuchando"
        case .connecting: "buscando"
        case .connected: "arriba"
        case let .failed(motivo): "fallido: \(motivo)"
        }
    }
}

extension RigLinkSession.State {
    /// En palabras, para el latido.
    public var label: String {
        switch self {
        case .searching: "buscando"
        case .authenticating: "autenticando"
        case let .connected(peer): "conectada con \(peer)"
        case let .rejected(motivo): "rechazada: \(motivo)"
        case .conflict: "conflicto de maestros"
        case .off: "apagada"
        }
    }
}
