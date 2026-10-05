// Las miniaturas del panel local (IOS-64): 640×360 en JPEG, a 1 fps como mucho.
//
// VTPixelTransferSession reduce el NV12 (4K de la cámara o 1080p del programa) a un
// BGRA de 640×360 en la GPU, sin pasar por CPU; ImageIO lo comprime. Los búferes de
// destino salen de un pool preasignado: a 1 fps no hace falta más, pero tampoco se
// reserva nada por llamada.

import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public enum ThumbnailConstants {
    public static let width = 640
    public static let height = 360
    /// Calidad del JPEG (0–1): ~30 KB a 640×360, lo que cabe en un LinkFrame.thumb.
    public static let jpegQuality = 0.6
}

public final class Thumbnailer {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let lock = NSLock()

    public init?(width: Int = ThumbnailConstants.width, height: Int = ThumbnailConstants.height) {
        var s: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else {
            return nil
        }
        VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &p)
        guard let p else { return nil }
        session = s
        pool = p
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// El JPEG de `source` reducido a 640×360 (con bandas si no es 16:9), o nil.
    public func jpeg(from source: CVPixelBuffer) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var destino: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destino)
        guard let destino, VTPixelTransferSessionTransferImage(session, from: source, to: destino) == noErr else {
            return nil
        }
        CVPixelBufferLockBaseAddress(destino, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destino, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(destino),
              let ctx = CGContext(
                  data: base, width: CVPixelBufferGetWidth(destino), height: CVPixelBufferGetHeight(destino),
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(destino),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let imagen = ctx.makeImage()
        else {
            return nil
        }
        let salida = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(salida, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, imagen, [
            kCGImageDestinationLossyCompressionQuality: ThumbnailConstants.jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return salida as Data
    }
}
