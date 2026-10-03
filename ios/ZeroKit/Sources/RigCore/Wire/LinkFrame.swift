// La trama del enlace entre los dos móviles (IOS-10, ADR 0023 §2).
//
// Cada mensaje es una LinkFrame: cabecera fija big-endian, payload y el `tag` de
// 16 B del sellado (decisión 3), que no va en `hello` ni en `auth` porque todavía no
// hay sesión que sellar. Por TCP las tramas van seguidas y `length` las separa; por
// UDP se trocean con `Fragmenter`.
//
// Los códigos de `type` los fija este fichero y NO SE REUTILIZAN: un tipo nuevo toma
// el siguiente número y sube `link_version`. El contenido de cada payload (JSON en
// control, binario en medios) lo definen sus tarjetas; aquí solo viven los que ya
// tienen formato cerrado (detecciones).

import Foundation

/// El catálogo del ADR 0023 §1, con su canal. Los crudos son el contrato del cable.
public enum LinkFrameType: UInt8, CaseIterable, Sendable {
    case hello = 1
    case auth = 2
    case command = 3
    case replica = 4
    case calib = 5
    case lookRequest = 6
    case look = 7
    case ptsRequest = 8
    case ptsReply = 9
    case handover = 10
    case handoverReply = 11
    case credentials = 12
    case telemetry = 13
    case thumb = 14
    case idrRequest = 15
    case legacy = 16
    case heartbeat = 17
    case clockPing = 18
    case clockPong = 19
    case detections = 20
    case view = 21
    case part = 22
    case noPart = 23
    case colorMeans = 24

    public var channel: LinkChannel {
        switch self {
        case .heartbeat, .clockPing, .clockPong, .detections, .view, .part, .noPart,
             .colorMeans:
            return .media
        default:
            return .control
        }
    }

    /// `hello` y `auth` van antes de que exista la sesión: sin `session` ni `tag`.
    public var preSession: Bool {
        self == .hello || self == .auth
    }
}

public enum LinkChannel: Sendable {
    /// TCP: fiable y en orden; lo que no puede perderse.
    case control
    /// UDP sin reintentos: lo que caduca antes de que llegue un reenvío.
    case media
}

public struct LinkFrame: Equatable, Sendable {
    public static let magic: UInt16 = 0x5A4C  // «ZL»
    public static let version: UInt8 = 1
    public static let tagLength = 16
    /// magic(2) + version(1) + type(1) + flags(1) + session(4) + seq(4) + rigMs(8) + length(4)
    public static let headerLength = 25

    /// Bit 0: la parte es un IDR. Bit 1: la vista es extrapolada. El resto, a 0.
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let idr = Flags(rawValue: 1 << 0)
        public static let extrapolated = Flags(rawValue: 1 << 1)
    }

    public var type: LinkFrameType
    public var flags: Flags
    /// El de la sesión (decisión 3); 0 solo en `hello` y `auth`.
    public var session: UInt32
    /// Por emisor y canal, desde 0 en cada sesión.
    public var seq: UInt32
    /// En detections, part y thumb, el instante de captura; en el resto, el de envío,
    /// o 0 si el emisor aún no tiene reloj.
    public var rigMs: UInt64
    public var payload: Data
    /// Los 16 B del sellado. Vacío en `hello` y `auth`.
    public var tag: Data

    public init(
        type: LinkFrameType,
        flags: Flags = [],
        session: UInt32,
        seq: UInt32,
        rigMs: UInt64,
        payload: Data,
        tag: Data = Data()
    ) {
        self.type = type
        self.flags = flags
        self.session = session
        self.seq = seq
        self.rigMs = rigMs
        self.payload = payload
        self.tag = tag
    }

    /// Cabecera ‖ payload, sin el tag: exactamente lo que se firma (ADR 0023 §3).
    public func signableBytes() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.appendBigEndian(Self.magic)
        data.append(Self.version)
        data.append(type.rawValue)
        data.append(flags.rawValue)
        data.appendBigEndian(session)
        data.appendBigEndian(seq)
        data.appendBigEndian(rigMs)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public func encode() -> Data {
        var data = signableBytes()
        if !type.preSession {
            // Un tag que no mida 16 B es un error del emisor, no del formato.
            precondition(tag.count == Self.tagLength, "el tag debe medir 16 B")
            data.append(tag)
        }
        return data
    }

    /// Qué salió de intentar leer una trama del principio de `data` (un stream TCP).
    public enum DecodeResult: Equatable, Sendable {
        /// Una trama entera, y cuántos bytes consumió.
        case frame(LinkFrame, consumed: Int)
        /// El principio es válido pero aún faltan bytes.
        case needsMoreData
        /// Eso no es nuestro (magic, versión, tipo o longitud): se tira y se cuenta.
        /// Por control, además, se cierra la conexión.
        case invalid(String)
    }

    public static func decode(from data: Data) -> DecodeResult {
        guard data.count >= headerLength else { return .needsMoreData }
        var reader = BigEndianReader(data: data)
        guard reader.read(UInt16.self) == magic else { return .invalid("magic") }
        guard reader.read(UInt8.self) == version else { return .invalid("version") }
        guard let rawType = reader.read(UInt8.self), let type = LinkFrameType(rawValue: rawType)
        else {
            return .invalid("type")
        }
        guard let rawFlags = reader.read(UInt8.self),
              let session = reader.read(UInt32.self),
              let seq = reader.read(UInt32.self),
              let rigMs = reader.read(UInt64.self),
              let length = reader.read(UInt32.self)
        else {
            return .needsMoreData
        }
        guard length <= LinkConstants.maxFrameB else { return .invalid("length") }
        let tagLength = type.preSession ? 0 : Self.tagLength
        let total = headerLength + Int(length) + tagLength
        guard data.count >= total else { return .needsMoreData }
        let payloadStart = data.startIndex + headerLength
        let payload = Data(data[payloadStart..<(payloadStart + Int(length))])
        let tag = Data(data[(payloadStart + Int(length))..<(data.startIndex + total)])
        let frame = LinkFrame(
            type: type,
            flags: Flags(rawValue: rawFlags),
            session: session,
            seq: seq,
            rigMs: rigMs,
            payload: payload,
            tag: tag
        )
        return .frame(frame, consumed: total)
    }
}

// MARK: - Detecciones (el único payload binario con formato cerrado hoy)

/// Una caja del detector en el cable: 10 B (u16 × 4 en píxeles nativos, clase u8 y
/// score u8). La tarjeta decía «9 B» pero las cuentas de su propia aceptación son
/// estas: 30 cajas = 300 B, el tope exacto.
public struct WireDetection: Equatable, Sendable {
    public var x1: UInt16
    public var y1: UInt16
    public var x2: UInt16
    public var y2: UInt16
    public var classId: UInt8
    /// score × 255, redondeado: 8 bits bastan para ordenar y filtrar.
    public var score: UInt8

    public init(x1: UInt16, y1: UInt16, x2: UInt16, y2: UInt16, classId: UInt8, score: UInt8) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.classId = classId
        self.score = score
    }
}

public enum DetectionsPayload {
    /// `infer_ms` u16 + número de cajas u16 + las cajas.
    public static func encode(inferMs: UInt16, detections: [WireDetection]) -> Data {
        var data = Data(capacity: 4 + detections.count * 10)
        data.appendBigEndian(inferMs)
        data.appendBigEndian(UInt16(clamping: detections.count))
        for caja in detections.prefix(Int(UInt16.max)) {
            data.appendBigEndian(caja.x1)
            data.appendBigEndian(caja.y1)
            data.appendBigEndian(caja.x2)
            data.appendBigEndian(caja.y2)
            data.append(caja.classId)
            data.append(caja.score)
        }
        return data
    }

    public static func decode(_ data: Data) -> (inferMs: UInt16, detections: [WireDetection])? {
        var reader = BigEndianReader(data: data)
        guard let inferMs = reader.read(UInt16.self), let count = reader.read(UInt16.self) else {
            return nil
        }
        var cajas: [WireDetection] = []
        cajas.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let x1 = reader.read(UInt16.self), let y1 = reader.read(UInt16.self),
                  let x2 = reader.read(UInt16.self), let y2 = reader.read(UInt16.self),
                  let clase = reader.read(UInt8.self), let score = reader.read(UInt8.self)
            else {
                return nil
            }
            cajas.append(WireDetection(x1: x1, y1: y1, x2: x2, y2: y2, classId: clase, score: score))
        }
        return (inferMs, cajas)
    }
}

// MARK: - Lectura y escritura big-endian compartidas

/// El lector de RigMessage, ascendido a utilidad del módulo: lo usan la trama, los
/// fragmentos y los payloads binarios.
struct BigEndianReader {
    let data: Data
    var offset = 0

    mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        let start = data.startIndex + offset
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: start..<(start + size)) }
        offset += size
        return T(bigEndian: value)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
