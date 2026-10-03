// El contrato del transporte del enlace (IOS-11, ADR 0023 §3).
//
// Quien lo usa (RigLinkSession, IOS-12) no sabe si debajo hay Network.framework, el
// loopback de un test o un transporte falso: ve tramas que entran, tramas que salen,
// el estado y por dónde va la ruta a internet. Escucha el IZQUIERDO y conecta el
// DERECHO, sin depender del rol: un relevo cambia quién manda, no quién escucha.

import Foundation
import RigCore

public enum LinkTransportState: Equatable, Sendable {
    case idle
    case listening
    case connecting
    case connected
    case failed(String)
}

public struct LinkTransportStats: Equatable, Sendable {
    public var framesSent = 0
    public var framesReceived = 0
    public var reconnects = 0
    /// Tramas tiradas por magic, versión, tipo o longitud. Por control, además, se
    /// cierra la conexión (ADR 0023 §2).
    public var invalidFrames = 0

    // El canal de medios (IOS-16): lo que la tarjeta pide contar.
    public var mediaFramesReceived = 0
    /// Tramas que faltaron, medidas por los huecos de `seq`.
    public var mediaLossGaps = 0
    /// Llegadas de medios separadas por más de 100 ms de la anterior.
    public var mediaStallsOver100Ms = 0

    public init() {}
}

public protocol LinkTransport: AnyObject {
    /// Trama completa recibida, con su canal. Llega en la cola del transporte.
    var onFrame: ((LinkFrame, LinkChannel) -> Void)? { get set }
    var onState: ((LinkTransportState) -> Void)? { get set }
    /// Qué interfaz lleva la ruta a internet ahora («en», «pdp_ip0», «lo0»…).
    var onPath: ((String) -> Void)? { get set }

    var state: LinkTransportState { get }
    var stats: LinkTransportStats { get }

    func start()
    func stop()
    func send(_ frame: LinkFrame, on channel: LinkChannel)
}
