// La media de color de una cámara dentro del solape (IOS-38).
//
// Cada móvil mide, a 0,5 Hz, la media BGR de los píxeles de su cámara que la OTRA
// cámara también ve. Las muestras se eligen una vez por soporte, en CPU con RigModel,
// con el paso de la referencia (PANORAMA_COLOR_MATCH_STRIDE); la medida lee solo esas
// muestras del NV12 y las pasa a BGR. A 0,5 Hz y con paso 8 son ~130 000 lecturas en 4K:
// en CPU cuesta menos que montar un kernel, así que la tarjeta (que pedía Metal) se
// queda en CPU a propósito.
//
// La referencia mide en el lienzo cosido; aquí cada uno mide en su búfer la misma zona
// del mundo. Las dos medias vienen de la misma escena, que es lo que importa al cociente.

import CoreVideo
import Foundation
import RigCore

public final class OverlapMeans {
    /// Posiciones (x, y) del búfer CRUDO de la cámara, en píxeles de luma.
    public let samples: [(x: Int, y: Int)]
    public let width: Int
    public let height: Int

    /// `mountedUpsideDown`: el búfer crudo está girado 180° respecto a rig.json.
    public init(
        rig: RigModel, side: CameraSide, width: Int, height: Int, mountedUpsideDown: Bool,
        stride: Int = RigConstants.panoramaColorMatchStride
    ) {
        self.width = width
        self.height = height
        let otra: CameraSide = side == .left ? .right : .left
        let intr = rig.camera(side).intrinsics
        // rig.json puede estar a otra resolución que el búfer: se escala al medir.
        let sx = Double(intr.width) / Double(width)
        let sy = Double(intr.height) / Double(height)
        var muestras: [(Int, Int)] = []
        for y in Swift.stride(from: stride / 2, to: height, by: stride) {
            for x in Swift.stride(from: stride / 2, to: width, by: stride) {
                let (ux, uy) = mountedUpsideDown
                    ? CameraMount.uprightPoint(x: Double(x), y: Double(y), width: width, height: height)
                    : (Double(x), Double(y))
                let dir = rig.directionOf(side, xPx: ux * sx, yPx: uy * sy)
                if rig.sees(otra, direction: dir) {
                    muestras.append((x, y))
                }
            }
        }
        samples = muestras
    }

    /// Hay muestras bastantes para medir (PANORAMA_COLOR_MATCH_MIN_PIXELS).
    public var measurable: Bool { samples.count >= RigConstants.panoramaColorMatchMinPixels }

    /// La media BGR (0–255) de las muestras en un NV12 de rango de vídeo BT.709, o nil si
    /// el solape es pequeño o el búfer no es del tamaño de las muestras.
    public func measure(_ buffer: CVPixelBuffer) -> [Double]? {
        guard measurable, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPlaneCount(buffer) == 2
        else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let y0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let c0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self)
        else {
            return nil
        }
        let sy = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let sc = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var suma = (b: 0.0, g: 0.0, r: 0.0)
        for (x, y) in samples {
            let luma = Double(y0[y * sy + x])
            let i = (y / 2) * sc + (x / 2) * 2
            let rgb = Self.bt709VideoToRgb(y: luma, cb: Double(c0[i]), cr: Double(c0[i + 1]))
            suma.b += rgb.b
            suma.g += rgb.g
            suma.r += rgb.r
        }
        let n = Double(samples.count)
        return [suma.b / n, suma.g / n, suma.r / n]
    }

    /// YCbCr de rango de vídeo (16–235 / 16–240), BT.709, a RGB 0–255 recortado.
    static func bt709VideoToRgb(y: Double, cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        let yy = (y - 16) * 255 / 219
        let u = (cb - 128) * 255 / 224
        let v = (cr - 128) * 255 / 224
        func c(_ x: Double) -> Double { min(255, max(0, x)) }
        return (
            c(yy + 1.5748 * v),
            c(yy - 0.1873 * u - 0.4681 * v),
            c(yy + 1.8556 * u)
        )
    }
}
