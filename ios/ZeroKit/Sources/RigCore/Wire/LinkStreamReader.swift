// El lector del canal de control: un stream TCP de LinkFrames seguidas, que `length`
// separa (ADR 0023 §2).
//
// Junta lo que llega a trozos y saca las tramas enteras, en orden. Lo ya leído se suelta
// de verdad. `Data.removeFirst(_:)` no lo hace: Data es su propio SubSequence, así que solo
// mueve el principio del slice y deja los bytes en el almacenamiento. Y el `append`
// siguiente escribe detrás de ellos. El búfer de control de NWLinkTransport hacía eso y
// guardaba todo lo recibido desde que subió la conexión. En el maestro eso son las
// miniaturas del esclavo, ~17-35 KB por segundo: los 1-2 MB/min que crecía solo con
// enlace (2026-10-10). Aquí lo que queda a medias se copia a un Data nuevo, así que el
// búfer guarda como mucho una trama sin terminar.

import Foundation

public struct LinkStreamReader: Sendable {
    /// Lo que sale de un trozo del stream.
    public struct Output: Equatable, Sendable {
        /// Las tramas enteras, en el orden en que llegaron.
        public var frames: [LinkFrame]
        /// El campo que no cuadró (magic, versión, tipo o longitud), o nil. Las tramas de
        /// antes de la basura salen igual; lo que había en el búfer ya se ha tirado, y por
        /// control la conexión se cierra (ADR 0023 §2).
        public var invalid: String?

        public init(frames: [LinkFrame], invalid: String? = nil) {
            self.frames = frames
            self.invalid = invalid
        }
    }

    /// Lo más que guarda el búfer entre dos trozos: una trama entera sin su último byte.
    /// Las de más de `LinkConstants.maxFrameB` son basura y se tiran.
    public static let maxRetainedBytes = LinkFrame.headerLength + LinkConstants.maxFrameB + LinkFrame.tagLength - 1

    private var pending = Data()

    public init() {}

    /// Los bytes que ocupa el búfer en su almacenamiento hasta el final de lo pendiente.
    /// Es el `endIndex`, no el `count`: si algún día se vuelve a recortar con
    /// `removeFirst`, aquí se ve todo lo leído que sigue en memoria.
    public var retainedBytes: Int { pending.endIndex }

    /// Mete un trozo recibido y devuelve las tramas que completa.
    public mutating func push(_ bytes: Data) -> Output {
        pending.append(bytes)
        var frames: [LinkFrame] = []
        var start = pending.startIndex
        while true {
            switch LinkFrame.decode(from: pending[start...]) {
            case let .frame(frame, consumed):
                frames.append(frame)
                start += consumed
            case .needsMoreData:
                keep(from: start)
                return Output(frames: frames)
            case let .invalid(campo):
                pending = Data()
                return Output(frames: frames, invalid: campo)
            }
        }
    }

    /// Una conexión nueva empieza de cero.
    public mutating func reset() {
        pending = Data()
    }

    /// Se queda solo con lo que falta por leer, en un almacenamiento propio.
    private mutating func keep(from start: Data.Index) {
        if start == pending.endIndex {
            pending = Data()
        } else if start != pending.startIndex || pending.startIndex != 0 {
            pending = Data(pending[start...])
        }
    }
}
