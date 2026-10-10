// Cómo se encuentran los dos móviles (IOS-14, ADR 0023 §3).
//
// NWLinkTransport hace lo mismo sea cual sea el medio: escucha el izquierdo, conecta el
// derecho, control por TCP y medios por UDP. Lo único que cambia es la cita: con qué
// listener se anuncia cada canal, con qué browser se busca y con qué parámetros va la
// conexión. Bonjour por la interfaz que se pida (Ethernet en el campo, Wi-Fi en el
// banco) es el predeterminado; Wi-Fi Aware, el plan B, está en WiFiAwareLink.swift.

import Foundation
import Network
import RigCore

public protocol LinkRendezvous {
    /// Para los logs y el informe del banco.
    var label: String { get }

    /// Los parámetros de una conexión del canal: la del que busca y la de un listener sin
    /// anuncio (los tests, por el loopback).
    func parameters(for channel: LinkChannel) -> NWParameters

    /// El listener que anuncia el canal (el izquierdo). `name` y `txt` son los del
    /// anuncio Bonjour; un medio sin TXT los ignora y se queda con el hello autenticado.
    func makeListener(for channel: LinkChannel, name: String, txt: [String: String]) throws -> NWListener

    /// El browser que busca el canal (el derecho).
    func makeBrowser(for channel: LinkChannel) throws -> NWBrowser

    /// Un error de Network en palabras del medio (Wi-Fi Aware dice si falta el
    /// entitlement o el emparejado).
    func explain(_ error: NWError) -> String

    /// Si el error de un listener o un browser dice que la cita caducó, y no que falló:
    /// Wi-Fi Aware deja de publicar y de suscribirse cuando ya ha encontrado a todos
    /// (`publisherTimeout`, `subscriberTimeout`), y las conexiones siguen. Bonjour no
    /// caduca.
    func isExpiry(_ error: NWError) -> Bool

    /// Segundos que se espera a que una conexión del control quede lista antes de darla
    /// por perdida y probar otra vez.
    var connectTimeoutS: Double { get }

    /// Segundos sin nada del otro por medios, con el enlace arriba, tras los que el enlace
    /// está muerto: se tiran el control y los medios y se vuelve a buscar (IOS-14c). nil,
    /// sin vigía: el medio avisa solo cuando la conexión muere (Ethernet, Wi-Fi).
    var silenceTimeoutS: Double? { get }
}

extension LinkRendezvous {
    public func explain(_ error: NWError) -> String { "\(error)" }

    public func isExpiry(_: NWError) -> Bool { false }

    public var connectTimeoutS: Double { NWLinkTransport.controlConnectTimeoutS }

    public var silenceTimeoutS: Double? { nil }
}

/// Bonjour por una interfaz: `.wiredEthernet` en el campo, `.wifi` en el banco y `nil`
/// para el loopback de los tests.
public struct BonjourRendezvous: LinkRendezvous {
    public static let controlServiceType = "_footballai-rig._tcp"
    public static let mediaServiceType = "_footballai-media._udp"

    public let interfaceType: NWInterface.InterfaceType?

    public init(interfaceType: NWInterface.InterfaceType?) {
        self.interfaceType = interfaceType
    }

    public var label: String {
        switch interfaceType {
        case .wiredEthernet?: "ethernet"
        case .wifi?: "wifi"
        case nil: "loopback"
        default: "otra"
        }
    }

    public func parameters(for channel: LinkChannel) -> NWParameters {
        let params: NWParameters = channel == .control ? .tcp : .udp
        if let interfaceType {
            params.requiredInterfaceType = interfaceType
        }
        // En la LAN del soporte no hay DNS ni rutas: nada de esperas de resolución.
        params.includePeerToPeer = false
        return params
    }

    public func makeListener(for channel: LinkChannel, name: String, txt: [String: String]) throws -> NWListener {
        let listener = try NWListener(using: parameters(for: channel))
        listener.service = NWListener.Service(
            name: name, type: Self.serviceType(for: channel), txtRecord: NWTXTRecord(txt)
        )
        return listener
    }

    public func makeBrowser(for channel: LinkChannel) throws -> NWBrowser {
        NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType(for: channel), domain: nil),
            using: parameters(for: channel)
        )
    }

    static func serviceType(for channel: LinkChannel) -> String {
        channel == .control ? controlServiceType : mediaServiceType
    }
}
