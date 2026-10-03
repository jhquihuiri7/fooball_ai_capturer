import CoreMedia
import VideoToolbox
import XCTest

import RigCore
@testable import RigMedia

/// La aceptación de IOS-50 en macOS: 300 fotogramas 1080p a 6 Mbit/s, codificados y
/// decodificados, con PSNR ≥38 dB y la SEI recuperada en el 100 %.
final class VideoEncoderTests: XCTestCase {
    private let ancho = 1920
    private let alto = 1080
    private let fotogramas = 300
    private let intervaloNs: Int64 = 33_333_333  // 30 fps

    /// La luma del fotograma `i` en la columna `x`: un degradado en bloques de 16 px
    /// que se desplaza un nivel por fotograma. Determinista, así el test regenera el
    /// original al comparar y no guarda 300 fotogramas en memoria.
    private func luma(x: Int, frame i: Int) -> UInt8 {
        UInt8(64 + (x / 16 + i) % 128)
    }

    private func makeFrame(_ i: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var creado: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &creado)
        let buffer = try XCTUnwrap(creado, "pool sin búfer (\(status))")
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
                (base + y * stride).copyMemory(
                    from: origen.baseAddress!, byteCount: ancho
                )
            }
        }
        let croma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let strideCroma = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        memset(croma, 128, strideCroma * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    func testThreeHundredFramesRoundTripWithSeiAndPsnr() throws {
        let encoder = try VideoEncoder(
            width: ancho, height: alto, bitrateBps: 6_000_000, viewId: 1
        )
        let pool = try XCTUnwrap(encoder.pixelBufferPool, "el codificador no expone su pool")

        // Codificar, drenando la cola por el camino: es acotada y tira lo viejo.
        var salida: [EncodedFrame] = []
        for i in 0..<fotogramas {
            let buffer = try makeFrame(i, pool: pool)
            encoder.encode(buffer, ptsNs: Int64(i) * intervaloNs, rigMs: UInt64(1000 + i))
            while let frame = encoder.pop() {
                salida.append(frame)
            }
        }
        encoder.flush()
        while let frame = encoder.pop() {
            salida.append(frame)
        }

        XCTAssertEqual(salida.count, fotogramas)
        XCTAssertEqual(encoder.encodeFailures, 0)
        XCTAssertEqual(encoder.queueCounts.dropped, 0)

        // La SEI, recuperada en el 100 % y con lo que se escribió.
        for (indice, frame) in salida.enumerated() {
            let sei = H264Sei.find(inAvcc: frame.data)
            XCTAssertEqual(sei?.rigMs, UInt64(1000 + indice), "fotograma \(indice)")
            XCTAssertEqual(sei?.viewId, 1, "fotograma \(indice)")
        }
        // GOP de 2 s a 30 fps: en 10 s tiene que haber al menos 5 IDR, y el primero serlo.
        XCTAssertTrue(salida[0].isKeyframe)
        XCTAssertGreaterThanOrEqual(salida.filter(\.isKeyframe).count, 5)

        // Ida y vuelta: el PSNR de la luma contra el original regenerado.
        let formato = try XCTUnwrap(salida[0].formatDescription)
        var creada: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formato, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil,
            decompressionSessionOut: &creada
        ), noErr)
        let decoder = try XCTUnwrap(creada)
        defer { VTDecompressionSessionInvalidate(decoder) }

        var errorTotal = 0.0  // suma de errores cuadráticos sobre todos los píxeles
        var decodificados = 0
        for frame in salida {
            // CoreMedia reserva y es dueño del bloque; los bytes se copian dentro.
            var blockBuffer: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: frame.data.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: frame.data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            ), noErr)
            frame.data.withUnsafeBytes { bytes in
                _ = CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: blockBuffer!,
                    offsetIntoDestination: 0, dataLength: frame.data.count
                )
            }
            var sampleBuffer: CMSampleBuffer?
            var tamano = frame.data.count
            XCTAssertEqual(CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: blockBuffer,
                formatDescription: salida[0].formatDescription,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &tamano,
                sampleBufferOut: &sampleBuffer
            ), noErr)

            let i = Int(frame.ptsNs / intervaloNs)
            VTDecompressionSessionDecodeFrame(
                decoder, sampleBuffer: sampleBuffer!, flags: [], infoFlagsOut: nil
            ) { status, _, imagen, _, _ in
                guard status == noErr, let imagen = imagen as CVPixelBuffer? else { return }
                CVPixelBufferLockBaseAddress(imagen, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(imagen, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(imagen, 0) else { return }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(imagen, 0)
                var errorFotograma = 0.0
                // Una fila de cada ocho basta para el PSNR y mantiene el test ágil.
                for y in Swift.stride(from: 0, to: self.alto, by: 8) {
                    let fila = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<self.ancho {
                        let diferencia = Double(fila[x]) - Double(self.luma(x: x, frame: i))
                        errorFotograma += diferencia * diferencia
                    }
                }
                errorTotal += errorFotograma
                decodificados += 1
            }
        }

        XCTAssertEqual(decodificados, fotogramas)
        let muestras = Double(fotogramas) * Double(alto / 8) * Double(ancho)
        let mse = errorTotal / muestras
        let psnr = 10 * log10(255.0 * 255.0 / max(mse, 1e-9))
        XCTAssertGreaterThanOrEqual(psnr, 38.0, "PSNR \(psnr) dB")
    }

    func testForceIDRAndBitrateChangeMidStream() throws {
        let encoder = try VideoEncoder(
            width: ancho, height: alto, bitrateBps: 6_000_000, viewId: 0
        )
        let pool = try XCTUnwrap(encoder.pixelBufferPool)
        var salida: [EncodedFrame] = []
        for i in 0..<30 {
            if i == 17 {
                encoder.forceIDR()
                try encoder.setBitrate(bps: 2_000_000)
            }
            encoder.encode(try makeFrame(i, pool: pool), ptsNs: Int64(i) * intervaloNs, rigMs: UInt64(i))
            while let frame = encoder.pop() {
                salida.append(frame)
            }
        }
        encoder.flush()
        while let frame = encoder.pop() {
            salida.append(frame)
        }

        XCTAssertEqual(salida.count, 30)
        let idr = salida.first { $0.rigMs == 17 }
        XCTAssertEqual(idr?.isKeyframe, true, "el fotograma pedido tiene que salir IDR")
    }
}
