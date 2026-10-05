// El flujo de las partes entre los dos móviles, lógica pura (IOS-52, ADR 0023 §5).
//
// El decodificador del maestro nunca puede recibir una cadena rota: un P cuyo anterior
// se perdió pinta basura hasta el siguiente IDR. Por eso, en los dos extremos:
// - el esclavo guarda como mucho 2 partes; si tiene que tirar una, tira también todas
//   las P hasta el IDR que fuerza a continuación;
// - el maestro, ante un hueco en `part_seq`, no pasa nada al decodificador hasta un IDR
//   y lo pide por control con cada parte que tira (`idr_request`).

import Foundation

/// Partes que el esclavo retiene hacia el cable (ADR 0023 §5: 2 fotogramas).
public enum PartFlowConstants {
    public static let sendQueueFrames = 2

    /// Peso de cada muestra en el jitter suavizado (RFC 3550 §6.4.1: 1/16).
    public static let jitterGain = 1.0 / 16.0

    /// Ventana de la tasa en Mbit/s, en ms.
    public static let rateWindowMs: Int64 = 1000
}

/// El lado del esclavo: la cola acotada hacia el cable.
public final class PartSendQueue {
    public let capacity: Int
    private var queue: [PartPacket] = []

    /// La cadena está rota: el siguiente fotograma tiene que ser un IDR. El codificador
    /// lo mira antes de cada fotograma.
    public private(set) var needsIdr = false
    public private(set) var dropped = 0
    public private(set) var idrRequests = 0

    public init(capacity: Int = PartFlowConstants.sendQueueFrames) {
        precondition(capacity >= 1, "la cola necesita sitio para una parte")
        self.capacity = capacity
    }

    public var count: Int { queue.count }

    /// Encola la parte recién codificada. `false` si se tiró: una P mientras se espera
    /// el IDR, o cualquiera con la cola llena (y entonces se espera un IDR).
    @discardableResult
    public func push(_ part: PartPacket) -> Bool {
        if part.isKey {
            needsIdr = false
        } else if needsIdr {
            dropped += 1
            return false
        }
        guard queue.count < capacity else {
            // Lo que ya está en cola es anterior y está entero; la cadena se rompe a
            // partir de esta, así que lo que venga detrás espera al IDR.
            dropped += 1
            needsIdr = true
            return false
        }
        queue.append(part)
        return true
    }

    /// La siguiente parte para el cable, la más vieja primero.
    public func pop() -> PartPacket? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// El maestro pidió un IDR (`idr_request`): no aceptará nada hasta uno, así que las P
    /// en cola ya no le sirven. Un IDR en cola se queda, con lo que le sigue: con él la
    /// cadena vuelve a empezar.
    public func requestIdr() {
        idrRequests += 1
        let antes = queue.count
        if let ultimoIdr = queue.lastIndex(where: \.isKey) {
            queue.removeSubrange(..<ultimoIdr)
        } else {
            queue.removeAll()
            needsIdr = true
        }
        dropped += antes - queue.count
    }
}

/// El lado del maestro: orden, huecos y la puerta del decodificador.
public final class PartReceiver {
    public enum Outcome: Equatable, Sendable {
        /// A decodificar: la cadena está entera.
        case decode(PartPacket)
        /// Vieja o repetida (llegó tras una más nueva): fuera, sin pedir nada.
        case dropOld
        /// Hay un hueco detrás y esta no es un IDR: fuera, y se pide un IDR con este
        /// part_seq.
        case awaitingIdr(requestIdr: UInt32)
    }

    private var lastSeq: UInt32?
    private var awaitingIdr = true

    public private(set) var received = 0
    public private(set) var decoded = 0
    /// Partes que faltaron, por los huecos de `part_seq`.
    public private(set) var lost = 0
    public private(set) var idrRequests = 0

    /// Jitter suavizado de llegada, en ms (RFC 3550).
    public private(set) var jitterMs = 0.0
    private var lastTransitMs: Int64?
    private var window: [(arrivalMs: Int64, bytes: Int)] = []

    public init() {}

    /// Una parte que llega, con su hora de llegada en el reloj del soporte.
    public func receive(_ part: PartPacket, arrivalMs: Int64) -> Outcome {
        received += 1
        account(part, arrivalMs: arrivalMs)
        if let previo = lastSeq {
            let salto = Int32(bitPattern: part.partSeq &- previo)
            if salto <= 0 {
                return .dropOld
            }
            if salto > 1 {
                lost += Int(salto) - 1
                awaitingIdr = true
            }
        }
        lastSeq = part.partSeq
        if awaitingIdr {
            guard part.isKey else {
                idrRequests += 1
                return .awaitingIdr(requestIdr: part.partSeq)
            }
            awaitingIdr = false
        }
        decoded += 1
        return .decode(part)
    }

    /// Mbit/s de las partes llegadas en la última ventana.
    public func mbps(nowMs: Int64) -> Double {
        let desde = nowMs - PartFlowConstants.rateWindowMs
        let bytes = window.filter { $0.arrivalMs > desde }.reduce(0) { $0 + $1.bytes }
        return Double(bytes * 8) / Double(PartFlowConstants.rateWindowMs) / 1000
    }

    private func account(_ part: PartPacket, arrivalMs: Int64) {
        let transito = arrivalMs - part.frameRigMs
        if let previo = lastTransitMs {
            let d = Double(abs(transito - previo))
            jitterMs += (d - jitterMs) * PartFlowConstants.jitterGain
        }
        lastTransitMs = transito
        window.append((arrivalMs, part.accessUnit.count))
        let desde = arrivalMs - PartFlowConstants.rateWindowMs
        window.removeAll { $0.arrivalMs <= desde }
    }
}
