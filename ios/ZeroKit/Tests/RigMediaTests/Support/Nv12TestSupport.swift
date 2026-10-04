// NV12 BT.709 de rango limitado en la CPU, para los tests de los kernels (IOS-40/41).

import CoreVideo
import Foundation
import Metal
@testable import RigMedia
import XCTest

let kr = 0.2126
let kb = 0.0722

/// Un CVPixelBuffer NV12 con IOSurface desde BGR, con la croma media de cada 2×2.
func nv12(bgr: [UInt8], ancho: Int, alto: Int) throws -> CVPixelBuffer {
    let pool = try XCTUnwrap(PixelBufferPool(
        width: ancho, height: alto,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, capacity: 1
    ))
    let buffer = try XCTUnwrap(pool.take())
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let lumaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cromaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * ancho + x) * 3
        return (Double(bgr[i + 2]) / 255, Double(bgr[i + 1]) / 255, Double(bgr[i]) / 255)
    }
    for y in 0..<alto {
        for x in 0..<ancho {
            let (r, g, b) = rgb(x, y)
            let yn = kr * r + (1 - kr - kb) * g + kb * b
            lumaPtr[y * lumaStride + x] = UInt8((16 + 219 * yn).rounded())
        }
    }
    for cy in 0..<(alto / 2) {
        for cx in 0..<(ancho / 2) {
            var (r, g, b) = (0.0, 0.0, 0.0)
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let p = rgb(cx * 2 + dx, cy * 2 + dy)
                r += p.0 / 4; g += p.1 / 4; b += p.2 / 4
            }
            let yn = kr * r + (1 - kr - kb) * g + kb * b
            cromaPtr[cy * cromaStride + cx * 2] = UInt8((128 + 224 * (b - yn) / (2 * (1 - kb))).rounded())
            cromaPtr[cy * cromaStride + cx * 2 + 1] = UInt8((128 + 224 * (r - yn) / (2 * (1 - kr))).rounded())
        }
    }
    return buffer
}

/// Los planos en crudo: luma (alto×ancho) y croma (Cb, Cr de cada 2×2).
func planes(nv12 buffer: CVPixelBuffer) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let ancho = CVPixelBufferGetWidth(buffer), alto = CVPixelBufferGetHeight(buffer)
    let lumaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cromaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    var y: [UInt8] = [], u: [UInt8] = [], v: [UInt8] = []
    for fila in 0..<alto {
        for x in 0..<ancho { y.append(lumaPtr[fila * lumaStride + x]) }
    }
    for fila in 0..<(alto / 2) {
        for x in 0..<(ancho / 2) {
            u.append(cromaPtr[fila * cromaStride + x * 2])
            v.append(cromaPtr[fila * cromaStride + x * 2 + 1])
        }
    }
    return (y, u, v)
}

/// BGR desde NV12, con la croma del 2×2 en cada píxel.
func bgr(nv12 buffer: CVPixelBuffer) -> [UInt8] {
    let (y, u, v) = planes(nv12: buffer)
    let ancho = CVPixelBufferGetWidth(buffer), alto = CVPixelBufferGetHeight(buffer)
    var salida = [UInt8](repeating: 0, count: ancho * alto * 3)
    func sat(_ x: Double) -> UInt8 { UInt8(min(max((x * 255).rounded(), 0), 255)) }
    for fila in 0..<alto {
        for x in 0..<ancho {
            let yn = (Double(y[fila * ancho + x]) - 16) / 219
            let c = (fila / 2) * (ancho / 2) + x / 2
            let cb = (Double(u[c]) - 128) / 224, cr = (Double(v[c]) - 128) / 224
            let r = yn + 2 * (1 - kr) * cr
            let b = yn + 2 * (1 - kb) * cb
            let g = (yn - kr * r - kb * b) / (1 - kr - kb)
            let i = (fila * ancho + x) * 3
            salida[i] = sat(b); salida[i + 1] = sat(g); salida[i + 2] = sat(r)
        }
    }
    return salida
}

func ejecutar(_ contexto: MetalContext, _ cuerpo: (MTLCommandBuffer) throws -> Void) throws {
    let cb = try XCTUnwrap(contexto.queue.makeCommandBuffer())
    try cuerpo(cb)
    cb.commit()
    cb.waitUntilCompleted()
    XCTAssertNil(cb.error)
}

/// PSNR en dB entre dos series de bytes; infinito si son iguales.
func psnrDb(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count)
    var s = 0.0
    for i in a.indices {
        let d = Double(a[i]) - Double(b[i])
        s += d * d
    }
    let mse = s / Double(max(a.count, 1))
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}
