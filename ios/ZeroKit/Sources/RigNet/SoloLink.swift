// «Una cámara (sin pareja)» (2026-10-15): la sesión del enlace sin nadie al otro lado.
//
// Es el modo degradado explícito de la arquitectura B con un solo móvil: el que lo elige
// en la pantalla de lado no abre Bonjour, ni Wi-Fi Aware, ni pide el secreto del soporte.
// La pasada del programa (SplitBench) habla con una RigLinkSession; aquí se le da una que
// dirige desde el primer instante, con su propio reloj de host como reloj del soporte y un
// transporte que no abre nada. Así EMITIR es el mismo camino que con dos, con la parte, las
// vistas y las órdenes cayendo en vacío porque nunca hay sesión conectada.

import Foundation
import RigCore

/// El transporte que no abre nada: ni escucha, ni conecta, ni manda. Lo que le llegue se
/// tira (y la sesión, sin conectar, ni se lo pasa).
public final class NoLinkTransport: LinkTransport {
    public var onFrame: ((LinkFrame, LinkChannel) -> Void)?
    public var onState: ((LinkTransportState) -> Void)?
    public var onPath: ((String) -> Void)?
    public let state: LinkTransportState = .idle
    public let stats = LinkTransportStats()

    public init() {}

    public func start() {}
    public func stop() {}
    public func send(_: LinkFrame, on _: LinkChannel) {}
}

public extension RigLinkSession {
    /// La sesión de «Una cámara»: sobre `NoLinkTransport` y sin secreto, porque nunca hay
    /// apretón de manos que firmar. Hay que arrancarla con `startAlone()`.
    static func alone(side: Side, deviceId: String, appVersion: String) -> RigLinkSession {
        let sesion = RigLinkSession(
            transport: NoLinkTransport(), secret: Data(), side: side, deviceId: deviceId, appVersion: appVersion
        )
        sesion.claimedRole = .master
        sesion.prefersMaster = true
        return sesion
    }
}
