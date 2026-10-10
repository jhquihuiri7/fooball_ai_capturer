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
    /// Tramas de medios tiradas al emitir porque la cola del espaciado estaba llena.
    public var mediaPacerDrops = 0

    /// Citas (listener o browser) que se acabaron sin que fuera un fallo del enlace:
    /// por Wi-Fi Aware caducan a los ~2 min de conectar y la conexión sigue (IOS-14).
    public var rendezvousEnds = 0

    /// Enlaces tirados por el vigía de silencio: arriba, pero sin nada del otro por medios
    /// durante el plazo de la cita (Wi-Fi Aware, IOS-14c).
    public var silenceDrops = 0

    /// Bytes recibidos por control (TCP). En el maestro son sobre todo las miniaturas del
    /// esclavo, a 1 Hz.
    public var controlBytesReceived = 0
    /// Lo más que ha guardado el búfer de control entre dos lecturas (en bytes de su
    /// almacenamiento): como mucho una trama a medias, `LinkStreamReader.maxRetainedBytes`.
    /// Antes del 2026-10-10 crecía con todo lo recibido.
    public var controlBufferPeakBytes = 0

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
