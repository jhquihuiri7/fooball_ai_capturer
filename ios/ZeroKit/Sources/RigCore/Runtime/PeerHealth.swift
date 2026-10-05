// La salud del otro móvil por el latido (IOS-81, ADR 0023 §6), lógica pura.
//
// Cada latido lleva el último `seq` de medios que su emisor oyó del otro. El enlace está
// ARRIBA solo si se oye en los dos sentidos: oigo un latido reciente Y ese latido dice
// que el otro oyó algo mío reciente. Así una pérdida en un solo sentido la ven los dos.
// Sin un latido bueno en HEARTBEAT_LOSS_MS, el otro está CAÍDO; a la mitad, DUDOSO.

import Foundation

public enum PeerState: String, Sendable {
    case up, suspect, down
}

/// Lo que dice un latido (decisión 1 del ADR: rol, term, escalera, estado y el último
/// seq oído al otro).
public struct Heartbeat: Equatable, Sendable {
    public let isMaster: Bool
    public let term: UInt32
    public let ladderLevel: UInt8
    public let cameraOk: Bool
    public let recording: Bool
    public let sendingParts: Bool
    /// El último seq de medios que el emisor oyó del receptor.
    public let lastHeardSeq: UInt32

    public init(isMaster: Bool, term: UInt32, ladderLevel: UInt8, cameraOk: Bool, recording: Bool,
                sendingParts: Bool, lastHeardSeq: UInt32) {
        self.isMaster = isMaster; self.term = term; self.ladderLevel = ladderLevel; self.cameraOk = cameraOk
        self.recording = recording; self.sendingParts = sendingParts; self.lastHeardSeq = lastHeardSeq
    }

    /// rol u8 ‖ term u32 ‖ escalera u8 ‖ estado u8 (bits: cámara, grabación, parte) ‖ seq u32.
    public func encode() -> Data {
        var d = Data()
        d.append(isMaster ? 1 : 0)
        d.appendBigEndian(term)
        d.append(ladderLevel)
        d.append((cameraOk ? 1 : 0) | (recording ? 2 : 0) | (sendingParts ? 4 : 0))
        d.appendBigEndian(lastHeardSeq)
        return d
    }

    public static func decode(_ data: Data) -> Heartbeat? {
        guard data.count == 11 else { return nil }
        var r = BigEndianReader(data: data)
        guard let rol = r.read(UInt8.self), let term = r.read(UInt32.self), let esc = r.read(UInt8.self),
              let estado = r.read(UInt8.self), let seq = r.read(UInt32.self), rol <= 1
        else { return nil }
        return Heartbeat(isMaster: rol == 1, term: term, ladderLevel: esc, cameraOk: estado & 1 != 0,
                         recording: estado & 2 != 0, sendingParts: estado & 4 != 0, lastHeardSeq: seq)
    }
}

public final class PeerHealth {
    public let lossMs: Int64
    /// Cuándo mandé cada seq de medios, los últimos: para saber si lo que el otro oyó
    /// es reciente.
    private var sentAt: [UInt32: Int64] = [:]
    private var sentOrder: [UInt32] = []
    private let sentMemory: Int
    private var lastGoodMs: Int64?
    public private(set) var state: PeerState = .down
    public private(set) var lastHeartbeat: Heartbeat?

    /// Cada cambio de estado.
    public var onChange: ((PeerState) -> Void)?

    public init(lossMs: Int64 = LinkConstants.heartbeatLossMs, sentMemory: Int = 256) {
        self.lossMs = lossMs
        self.sentMemory = sentMemory
    }

    /// Mandé el seq de medios `seq` en `nowMs`.
    public func sent(seq: UInt32, nowMs: Int64) {
        sentAt[seq] = nowMs
        sentOrder.append(seq)
        if sentOrder.count > sentMemory {
            sentAt[sentOrder.removeFirst()] = nil
        }
    }

    /// Llegó un latido del otro en `nowMs`.
    public func heard(_ hb: Heartbeat, nowMs: Int64) {
        lastHeartbeat = hb
        // El enlace está probado en los dos sentidos hasta cuando mandé lo que el otro
        // dice haber oído: desde ESE instante corre el plazo, no desde ahora (si no, un
        // corte de ida se vería con el doble de retraso).
        if let cuando = sentAt[hb.lastHeardSeq] {
            lastGoodMs = max(lastGoodMs ?? cuando, cuando)
        }
        tick(nowMs: nowMs)
    }

    /// El estado en `nowMs` (llamarlo a menudo: también el tiempo lo cambia).
    @discardableResult
    public func tick(nowMs: Int64) -> PeerState {
        let nuevo: PeerState
        if let ultimo = lastGoodMs {
            let hueco = nowMs - ultimo
            nuevo = hueco > lossMs ? .down : (hueco > lossMs / 2 ? .suspect : .up)
        } else {
            nuevo = .down
        }
        if nuevo != state {
            state = nuevo
            onChange?(nuevo)
        }
        return state
    }

    /// El control se cerró: caído al momento (ADR 0023 §6).
    public func controlClosed() {
        lastGoodMs = nil
        if state != .down {
            state = .down
            onChange?(.down)
        }
    }
}
