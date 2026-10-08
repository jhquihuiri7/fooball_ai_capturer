// Por dónde va el enlace entre los dos móviles (ADR 0023 §3; IOS-14).
//
// Hoy lo elige quien lanza la app, con RIG_LINK_INTERFACE: el hub por Ethernet en el
// campo, la Wi-Fi del router en el banco, o Wi-Fi Aware, el plan B sin router. La
// elección automática (Ethernet si hay ruta cableada; si no, Wi-Fi Aware) y el cambio
// en caliente sin cortar el reloj llegan con IOS-17, en este mismo fichero.

import Foundation

/// El medio del enlace. El protocolo (tramas, hello, sesión) es el mismo en los tres;
/// cambia cómo se encuentran los dos móviles y cuánto cabe.
public enum LinkMedium: String, CaseIterable, Sendable {
    /// El hub USB-C con Ethernet: el del campo (ADR 0023).
    case ethernet
    /// La Wi-Fi de un router: el banco sin cables.
    case wifi
    /// Wi-Fi Aware entre los dos iPhone, sin router (IOS-14). Pide emparejarlos una vez.
    case aware

    /// Lo que se acepta en RIG_LINK_INTERFACE además de los nombres de los casos.
    static let aliases: [String: LinkMedium] = ["wifi-aware": .aware, "nan": .aware]

    /// RIG_LINK_INTERFACE: sin valor es Ethernet, el predeterminado; un valor que no se
    /// entiende es nil, para que quien lanza falle claro en vez de ir por el cable sin
    /// saberlo.
    public static func parse(_ setting: String?) -> LinkMedium? {
        let valor = (setting ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if valor.isEmpty { return .ethernet }
        return LinkMedium(rawValue: valor) ?? aliases[valor]
    }

    /// Bits por segundo de la parte del esclavo por este medio.
    public var partBitrateBps: Int {
        switch self {
        case .ethernet: LinkConstants.partBitrateEthernetBps
        case .wifi: LinkConstants.partBitrateWifiBps
        case .aware: Self.partBitrateAwareBps
        }
    }

    /// Bits por segundo de la parte por Wi-Fi Aware: el de la Wi-Fi hasta que SPK-08 lo
    /// mida. Un solo salto por el aire, en vez de los dos de pasar por el router, debería
    /// dar más; hasta tener la cifra, se va a lo seguro.
    public static let partBitrateAwareBps = LinkConstants.partBitrateWifiBps

    /// Si hay que emparejar los dos móviles antes de que se vean: Wi-Fi Aware solo
    /// descubre a dispositivos emparejados.
    public var needsPairing: Bool { self == .aware }
}
