// Troceado y reensamblado de tramas para el canal de medios (IOS-10, ADR 0023 §2).
//
// Una LinkFrame grande (una parte de vídeo) no cabe en un datagrama: se trocea en
// fragmentos de ≤LINK_DATAGRAM_PAYLOAD_B y se reensambla por `seq` al otro lado. Las
// tramas a medias se acotan POR NÚMERO, como el FramePairer del servidor: la quinta
// expulsa a la más vieja. Un fragmento perdido tira la trama entera y se cuenta: en el
// canal de medios un reenvío llega tarde siempre.

import Foundation

public enum Fragmenter {
    /// Cabecera de cada datagrama: magic(2) + session(4) + seq(4) + index(2) + total(2).
    public static let datagramHeaderLength = 14

    /// Trocea una trama ya codificada. Devuelve al menos un datagrama.
    public static func fragment(frame: Data, session: UInt32, seq: UInt32) -> [Data] {
        let chunk = LinkConstants.datagramPayloadB
        let total = max(1, (frame.count + chunk - 1) / chunk)
        precondition(total <= Int(UInt16.max), "la trama no cabe en 65535 fragmentos")
        return (0..<total).map { index in
            var datagram = Data(capacity: datagramHeaderLength + chunk)
            datagram.appendBigEndian(LinkFrame.magic)
            datagram.appendBigEndian(session)
            datagram.appendBigEndian(seq)
            datagram.appendBigEndian(UInt16(index))
            datagram.appendBigEndian(UInt16(total))
            let start = frame.startIndex + index * chunk
            let end = min(start + chunk, frame.endIndex)
            datagram.append(frame[start..<end])
            return datagram
        }
    }
}

/// El otro lado: junta fragmentos hasta tener la trama. Uno por enlace y canal.
public final class Reassembler {
    private struct Partial {
        var fragments: [Data?]
        var received = 0
        var firstSeenOrder: Int
    }

    private var partials: [UInt32: Partial] = [:]
    private var arrivalCounter = 0
    public let maxPartials: Int

    /// Tramas tiradas por expulsión (llegó la N+1.ª a medias) o por basura.
    public private(set) var incompleteFrames = 0
    public private(set) var invalidDatagrams = 0

    public init(maxPartials: Int = LinkConstants.reassemblyFrames) {
        self.maxPartials = maxPartials
    }

    /// Mete un datagrama. Devuelve la trama completa cuando este era el último hueco.
    public func push(_ datagram: Data) -> Data? {
        var reader = BigEndianReader(data: datagram)
        guard reader.read(UInt16.self) == LinkFrame.magic,
              reader.read(UInt32.self) != nil,  // session: la valida la capa de sesión
              let seq = reader.read(UInt32.self),
              let index = reader.read(UInt16.self),
              let total = reader.read(UInt16.self),
              total > 0, index < total
        else {
            invalidDatagrams += 1
            return nil
        }
        let payload = Data(datagram[(datagram.startIndex + Fragmenter.datagramHeaderLength)...])

        var partial: Partial
        if let existing = partials[seq] {
            partial = existing
            guard existing.fragments.count == Int(total) else {
                // Dos totales distintos para el mismo seq: basura. Fuera la trama.
                partials[seq] = nil
                incompleteFrames += 1
                invalidDatagrams += 1
                return nil
            }
        } else {
            arrivalCounter += 1
            partial = Partial(
                fragments: Array(repeating: nil, count: Int(total)),
                firstSeenOrder: arrivalCounter
            )
            // El hueco N+1 expulsa a la trama a medias más vieja, que ya no se completa.
            if partials.count >= maxPartials,
               let victima = partials.min(by: { $0.value.firstSeenOrder < $1.value.firstSeenOrder }) {
                partials[victima.key] = nil
                incompleteFrames += 1
            }
        }

        if partial.fragments[Int(index)] == nil {
            partial.fragments[Int(index)] = payload
            partial.received += 1
        }
        if partial.received == partial.fragments.count {
            partials[seq] = nil
            return partial.fragments.reduce(into: Data()) { $0.append($1!) }
        }
        partials[seq] = partial
        return nil
    }
}
