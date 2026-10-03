// Lo que viaja por el enlace entre los dos móviles (ADR 0012, decisión 2; TASK A3 y A4).
//
// Binario, big-endian y de tamaño fijo salvo la lista de PTS. La sesión Multipeer, los
// sellos de reloj y todo lo que toca iOS quedan en Runner (RigLink.swift): aquí vive
// solo el formato, que es lo que tiene que ser idéntico en los dos lados del cable.

import Foundation

/// Las órdenes que caben en el cable, con su byte. Es el catálogo del **formato**, no
/// el de la API de la app: el `RigCommand` de pigeon vive en Runner, y un test de
/// RunnerTests comprueba que los dos no divergen. Una orden que este móvil no conoce
/// se ignora entera: mejor no grabar que grabar por un byte que vino de una versión
/// distinta de la app.
public enum RigWireCommand: UInt8, CaseIterable, Sendable {
    case record = 0
    case recordAndSave = 1
    case stop = 2
    case calibrate = 3
}

/// Lo que viaja por el enlace. Binario, big-endian y de tamaño fijo salvo la lista de PTS.
public enum RigMessage: Equatable, Sendable {
    /// Pregunta de hora. `t1` es cuándo salió, en el reloj del que pregunta.
    case ping(seq: UInt32, t1: Int64)
    /// Respuesta. Devuelve `t1` y añade cuándo llegó (`t2`) y cuándo sale (`t3`), en el
    /// reloj del maestro.
    case pong(seq: UInt32, t1: Int64, t2: Int64, t3: Int64)
    /// El derecho pide los PTS recientes del maestro para medir la fase (TASK A4).
    case ptsRequest(seq: UInt32)
    case ptsReply(seq: UInt32, pts: [Int64])
    /// El derecho pregunta cómo ve el maestro (exposición y balance de blancos)...
    case lookRequest(seq: UInt32)
    /// ...y el maestro contesta; también lo manda por su cuenta cuando los cambia.
    case look(seq: UInt32, look: CameraLook)
    /// El maestro manda: grabar, parar o calibrar. Va por el canal fiable, porque
    /// perder un «graba» deja el partido a media cámara y nadie se entera hasta el final.
    case command(seq: UInt32, command: RigWireCommand)

    private enum Kind: UInt8 {
        case ping = 1, pong, ptsRequest, ptsReply, lookRequest, look, command
    }

    public func encode() -> Data {
        var data = Data()
        switch self {
        case let .ping(seq, t1):
            data.append(Kind.ping.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(t1)
        case let .pong(seq, t1, t2, t3):
            data.append(Kind.pong.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(t1)
            data.appendBigEndian(t2)
            data.appendBigEndian(t3)
        case let .ptsRequest(seq):
            data.append(Kind.ptsRequest.rawValue)
            data.appendBigEndian(seq)
        case let .ptsReply(seq, pts):
            data.append(Kind.ptsReply.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(UInt16(clamping: pts.count))
            pts.prefix(Int(UInt16.max)).forEach { data.appendBigEndian($0) }
        case let .lookRequest(seq):
            data.append(Kind.lookRequest.rawValue)
            data.appendBigEndian(seq)
        case let .look(seq, look):
            data.append(Kind.look.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(look.exposureNs)
            // Los decimales viajan con sus bits tal cual: sin redondeos ni escalas que acordar.
            [look.iso, look.aperture, look.kelvin, look.tint].forEach { data.appendBigEndian($0.bitPattern) }
        case let .command(seq, command):
            data.append(Kind.command.rawValue)
            data.appendBigEndian(seq)
            data.append(command.rawValue)
        }
        return data
    }

    /// `nil` si el paquete está truncado o no es nuestro: se ignora, no se revienta.
    public static func decode(_ data: Data) -> RigMessage? {
        var reader = Reader(data: data)
        guard let raw = reader.read(UInt8.self), let kind = Kind(rawValue: raw),
              let seq = reader.read(UInt32.self)
        else {
            return nil
        }
        switch kind {
        case .ping:
            guard let t1 = reader.read(Int64.self) else { return nil }
            return .ping(seq: seq, t1: t1)
        case .pong:
            guard let t1 = reader.read(Int64.self), let t2 = reader.read(Int64.self),
                  let t3 = reader.read(Int64.self)
            else {
                return nil
            }
            return .pong(seq: seq, t1: t1, t2: t2, t3: t3)
        case .ptsRequest:
            return .ptsRequest(seq: seq)
        case .ptsReply:
            guard let count = reader.read(UInt16.self) else { return nil }
            var pts: [Int64] = []
            for _ in 0..<count {
                guard let value = reader.read(Int64.self) else { return nil }
                pts.append(value)
            }
            return .ptsReply(seq: seq, pts: pts)
        case .lookRequest:
            return .lookRequest(seq: seq)
        case .look:
            guard let exposureNs = reader.read(Int64.self), let iso = reader.read(UInt32.self),
                  let aperture = reader.read(UInt32.self), let kelvin = reader.read(UInt32.self),
                  let tint = reader.read(UInt32.self)
            else {
                return nil
            }
            let look = CameraLook(
                exposureNs: exposureNs,
                iso: Float(bitPattern: iso),
                aperture: Float(bitPattern: aperture),
                kelvin: Float(bitPattern: kelvin),
                tint: Float(bitPattern: tint)
            )
            // Un paquete corrupto no debe llegar a la cámara como un ISO infinito.
            guard exposureNs > 0, [look.iso, look.aperture, look.kelvin, look.tint].allSatisfy(\.isFinite),
                  look.iso > 0
            else {
                return nil
            }
            return .look(seq: seq, look: look)
        case .command:
            guard let raw = reader.read(UInt8.self), let command = RigWireCommand(rawValue: raw)
            else {
                return nil
            }
            return .command(seq: seq, command: command)
        }
    }

    private struct Reader {
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
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        // `Swift.`: dentro de una extensión de `Data`, el nombre a secas es el método de `Data`.
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
