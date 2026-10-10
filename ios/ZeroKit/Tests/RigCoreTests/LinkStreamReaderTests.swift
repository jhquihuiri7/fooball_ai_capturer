import XCTest

@testable import RigCore

/// El lector del canal de control (2026-10-10): tramas a trozos, basura y, sobre todo,
/// que lo ya leído no se queda en memoria.
final class LinkStreamReaderTests: XCTestCase {
    private let tag = Data(repeating: 0xAB, count: LinkFrame.tagLength)

    /// Una miniatura como las que manda el esclavo por control (~30 KB a 1 Hz).
    private func thumb(seq: UInt32, bytes: Int = 30_000) -> LinkFrame {
        LinkFrame(
            type: .thumb, session: 7, seq: seq, rigMs: UInt64(seq) * 1000,
            payload: Data(repeating: UInt8(truncatingIfNeeded: seq), count: bytes), tag: tag
        )
    }

    /// `bytes` bytes del stream que repite `frame` sin fin, desde la posición `from`.
    private func chunk(of frame: Data, from: Int, bytes: Int) -> Data {
        var trozo = Data(capacity: bytes)
        var p = from
        while trozo.count < bytes {
            let dentro = p % frame.count
            let n = min(bytes - trozo.count, frame.count - dentro)
            trozo.append(frame[dentro..<(dentro + n)])
            p += n
        }
        return trozo
    }

    func testFramesCutAnywhereComeOutWholeAndInOrder() {
        let tramas = (1...5).map { thumb(seq: $0, bytes: 100 * Int($0)) }
        let stream = tramas.reduce(into: Data()) { $0.append($1.encode()) }
        for trozo in [1, 7, LinkFrame.headerLength, LinkFrame.headerLength + 1, 333, stream.count] {
            var lector = LinkStreamReader()
            var salieron: [LinkFrame] = []
            var i = 0
            while i < stream.count {
                let fin = min(i + trozo, stream.count)
                let salida = lector.push(stream.subdata(in: i..<fin))
                XCTAssertNil(salida.invalid)
                salieron += salida.frames
                i = fin
            }
            XCTAssertEqual(salieron, tramas, "trozos de \(trozo) B")
            XCTAssertEqual(lector.retainedBytes, 0, "trozos de \(trozo) B")
        }
    }

    /// Lo que pasaba en el maestro: una miniatura por segundo durante un partido (5400),
    /// leídas a trozos de 64 KB que cortan las tramas por cualquier sitio. Con
    /// `removeFirst`, el búfer acababa guardando los ~160 MB recibidos. Ahora, entre dos
    /// lecturas, como mucho una trama a medias.
    func testAMatchOfThumbnailsLeavesAtMostOneHalfFrame() {
        let una = thumb(seq: 1).encode()
        let partido = 5400
        let total = una.count * partido
        var lector = LinkStreamReader()
        var tramas = 0
        var maximo = 0
        var posicion = 0
        while posicion < total {
            let n = min(LinkConstants.controlReadChunkB, total - posicion)
            let salida = lector.push(chunk(of: una, from: posicion, bytes: n))
            XCTAssertNil(salida.invalid)
            tramas += salida.frames.count
            maximo = max(maximo, lector.retainedBytes)
            posicion += n
        }
        XCTAssertEqual(tramas, partido)
        XCTAssertLessThan(maximo, una.count, "nunca más que una trama a medias")
        XCTAssertLessThanOrEqual(maximo, LinkStreamReader.maxRetainedBytes)
        XCTAssertEqual(lector.retainedBytes, 0)
    }

    /// El testigo del fallo: en un Data, `removeFirst` solo corre el principio del slice y
    /// el almacenamiento sigue con lo leído. Por eso `retainedBytes` mide el `endIndex`.
    func testDataRemoveFirstKeepsWhatWasConsumed() {
        var d = Data()
        for _ in 0..<10 {
            d.append(Data(count: 1000))
            d.removeFirst(1000)
        }
        XCTAssertEqual(d.count, 0)
        XCTAssertEqual(d.endIndex, 10_000, "los 10 000 B leídos siguen en el almacenamiento")
    }

    func testGarbageKeepsTheFramesBeforeItAndEmptiesTheBuffer() {
        var stream = thumb(seq: 1, bytes: 10).encode()
        stream.append(Data(repeating: 0xFF, count: LinkFrame.headerLength))
        var lector = LinkStreamReader()
        let salida = lector.push(stream)
        XCTAssertEqual(salida.frames, [thumb(seq: 1, bytes: 10)])
        XCTAssertEqual(salida.invalid, "magic")
        XCTAssertEqual(lector.retainedBytes, 0)
    }

    /// Una longitud disparatada se tira con la cabecera, sin esperar a sus bytes: el
    /// búfer nunca guarda más que una trama válida.
    func testAnOversizedLengthIsGarbageBeforeItsBytesArrive() {
        var cabecera = Data()
        cabecera.appendBigEndian(LinkFrame.magic)
        cabecera.append(LinkFrame.version)
        cabecera.append(LinkFrameType.thumb.rawValue)
        cabecera.append(0)
        cabecera.appendBigEndian(UInt32(7))
        cabecera.appendBigEndian(UInt32(1))
        cabecera.appendBigEndian(UInt64(0))
        cabecera.appendBigEndian(UInt32(LinkConstants.maxFrameB + 1))
        var lector = LinkStreamReader()
        let salida = lector.push(cabecera)
        XCTAssertEqual(salida.frames, [])
        XCTAssertEqual(salida.invalid, "length")
        XCTAssertEqual(lector.retainedBytes, 0)
    }

    func testResetDropsAHalfFrame() {
        let entera = thumb(seq: 2, bytes: 1000).encode()
        var lector = LinkStreamReader()
        XCTAssertEqual(lector.push(entera.prefix(500)).frames, [])
        XCTAssertEqual(lector.retainedBytes, 500)
        lector.reset()
        XCTAssertEqual(lector.retainedBytes, 0)
        XCTAssertEqual(lector.push(entera).frames, [thumb(seq: 2, bytes: 1000)])
    }
}
