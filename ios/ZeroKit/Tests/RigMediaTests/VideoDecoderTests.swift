import CoreMedia
import VideoToolbox
import XCTest

import RigCore
@testable import RigMedia

/// La aceptación de IOS-51 en macOS: la ida y vuelta con el codificador de IOS-50
/// (SPS/PPS en banda, SEI leída, IOSurface a la salida) y el hueco que pide IDR.
final class VideoDecoderTests: XCTestCase {
    private let ancho = 1280
    private let alto = 720
    private let intervaloNs: Int64 = 33_333_333

    private func luma(x: Int, frame i: Int) -> UInt8 {
        UInt8(64 + (x / 16 + i) % 128)
    }

    private func makeFrame(_ i: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var creado: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &creado)
        let buffer = try XCTUnwrap(creado)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var fila = [UInt8](repeating: 0, count: ancho)
        for x in 0..<ancho {
            fila[x] = luma(x: x, frame: i)
        }
        for y in 0..<alto {
            fila.withUnsafeBytes { origen in
                (base + y * stride).copyMemory(from: origen.baseAddress!, byteCount: ancho)
            }
        }
        let croma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        memset(croma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    /// Codifica `cuantos` fotogramas y devuelve las muestras como viajarían por el
    /// enlace: con los SPS/PPS en banda pegados delante de cada IDR (IOS-52).
    private func encodeFrames(_ cuantos: Int) throws -> [EncodedFrame] {
        let encoder = try VideoEncoder(width: ancho, height: alto, bitrateBps: 4_000_000, viewId: 0)
        let pool = try XCTUnwrap(encoder.pixelBufferPool)
        var salida: [EncodedFrame] = []
        for i in 0..<cuantos {
            encoder.encode(try makeFrame(i, pool: pool), ptsNs: Int64(i) * intervaloNs, rigMs: UInt64(i))
            while let frame = encoder.pop() {
                salida.append(frame)
            }
        }
        encoder.flush()
        while let frame = encoder.pop() {
            salida.append(frame)
        }
        return salida.map { frame in
            guard frame.isKeyframe, let formato = frame.formatDescription else { return frame }
            var data = H264ParameterSets.avccNals(from: formato)
            data.append(frame.data)
            return EncodedFrame(
                data: data, isKeyframe: true, rigMs: frame.rigMs,
                viewId: frame.viewId, ptsNs: frame.ptsNs, formatDescription: formato
            )
        }
    }

    func testRoundTripWithInBandParameterSetsAndSei() throws {
        let muestras = try encodeFrames(30)
        XCTAssertEqual(muestras.count, 30)

        let decoder = VideoDecoder()
        nonisolated(unsafe) var idrRequests = 0
        decoder.onNeedsIDR = { idrRequests += 1 }

        var decodificados: [DecodedFrame] = []
        for muestra in muestras {
            decoder.decode(avcc: muestra.data, ptsNs: muestra.ptsNs)
            while let frame = decoder.pop() {
                decodificados.append(frame)
            }
        }

        XCTAssertEqual(decodificados.count, 30)
        XCTAssertEqual(decoder.decodeFailures, 0)
        XCTAssertEqual(idrRequests, 0, "con el stream entero nadie pide IDR")
        // La SEI sobrevive a la ida y vuelta, fotograma a fotograma.
        for frame in decodificados {
            XCTAssertEqual(frame.rigMs, UInt64(frame.ptsNs / intervaloNs))
            XCTAssertEqual(frame.viewId, 0)
        }
        // La salida es NV12 sobre IOSurface, lista para Metal.
        let imagen = decodificados[0].pixelBuffer
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(imagen),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertNotNil(CVPixelBufferGetIOSurface(imagen))
        // Y es la imagen de verdad: la luma decodificada se parece a la original.
        CVPixelBufferLockBaseAddress(imagen, .readOnly)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(imagen, 0))
        let fila = base.assumingMemoryBound(to: UInt8.self)
        var error = 0.0
        for x in 0..<ancho {
            let diferencia = Double(fila[x]) - Double(luma(x: x, frame: 0))
            error += diferencia * diferencia
        }
        CVPixelBufferUnlockBaseAddress(imagen, .readOnly)
        let psnr = 10 * log10(255.0 * 255.0 / max(error / Double(ancho), 1e-9))
        XCTAssertGreaterThanOrEqual(psnr, 38.0, "PSNR \(psnr) dB en la primera fila")
    }

    func testAGapAsksForIDRAndResumesOnTheNextKeyframe() throws {
        let muestras = try encodeFrames(30)
        let decoder = VideoDecoder()
        nonisolated(unsafe) var idrRequests = 0
        decoder.onNeedsIDR = { idrRequests += 1 }

        // Los primeros cinco llegan bien.
        for muestra in muestras.prefix(5) {
            decoder.decode(avcc: muestra.data, ptsNs: muestra.ptsNs)
        }
        while decoder.pop() != nil {}

        // El transporte pierde el sexto: lo que sigue no tiene referencia.
        decoder.reportGap()
        XCTAssertEqual(idrRequests, 1)

        var decodificadosTrasHueco = 0
        for muestra in muestras.suffix(from: 6) where !muestra.isKeyframe {
            decoder.decode(avcc: muestra.data, ptsNs: muestra.ptsNs)
            while decoder.pop() != nil {
                decodificadosTrasHueco += 1
            }
            if muestra.ptsNs > muestras[10].ptsNs { break }
        }
        XCTAssertEqual(decodificadosTrasHueco, 0, "sin IDR no sale nada")
        XCTAssertGreaterThan(decoder.droppedWaitingIDR, 0)
        XCTAssertGreaterThan(idrRequests, 1, "se insiste hasta que llega")

        // Llega el IDR pedido (se reutiliza el primero): el stream se reabre.
        let idr = try XCTUnwrap(muestras.first { $0.isKeyframe })
        decoder.decode(avcc: idr.data, ptsNs: idr.ptsNs)
        var reabiertos = 0
        while decoder.pop() != nil {
            reabiertos += 1
        }
        XCTAssertEqual(reabiertos, 1)
    }
}
