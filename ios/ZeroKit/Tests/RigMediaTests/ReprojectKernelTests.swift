// El kernel de la parte contra los programas dorados de REF (IOS-40).
//
// Los dorados son de ViewRenderer.render (reprojection.json): fotogramas BGR y el
// programa BGR que pinta la referencia. Aquí cada fotograma se pasa a NV12 BT.709 de
// rango limitado, el kernel pinta la parte de cada lado y la costura se mezcla en la
// CPU con la fórmula exacta de la ruta GPU de la referencia (la costura es de IOS-41).
// La comparación es por PSNR de LUMA (Y BT.709), que es lo que el NV12 lleva a
// resolución completa: los fotogramas dorados son un tablero magenta/verde de 8 px y
// un degradado saturado con bordes duros, y su croma no sobrevive al 4:2:0 ni con una
// ida y vuelta sin kernel (33,6 dB en BGR solo por convertir). El color se comprueba
// aparte, sobre parches uniformes, donde el submuestreo no pierde nada.

import CoreVideo
import Foundation
import Metal
import RigCore
@testable import RigMedia
import XCTest

final class ReprojectKernelTests: XCTestCase {
    private static let psnrValidaDb = 45.0
    private static let psnrRampaDb = 38.0

    func testLosProgramasDoradosDeREF() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ReprojectKernel(context: contexto)
        let casos = try Self.casosRender()
        XCTAssertGreaterThanOrEqual(casos.count, 2)
        for caso in casos {
            let programa = try Self.pintar(caso, kernel: kernel, contexto: contexto)
            let (valida, rampa) = Self.psnr(programa: programa, caso: caso)
            XCTAssertGreaterThanOrEqual(valida, Self.psnrValidaDb, "\(caso.nombre): zona válida")
            if let rampa {
                XCTAssertGreaterThanOrEqual(rampa, Self.psnrRampaDb, "\(caso.nombre): rampa")
            }
        }
    }

    func testLaFranjaDelCodigoDeTiempoNoSale() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ReprojectKernel(context: contexto)
        let (ancho, alto) = (64, 32)
        let blanco = [UInt8](repeating: 255, count: ancho * alto * 3)
        let fuente = try Self.nv12(bgr: blanco, ancho: ancho, alto: alto)
        let destino = try Self.nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        // Identidad: el programa es la cámara tal cual, con la franja de abajo tapada.
        try Self.ejecutar(contexto) {
            try kernel.encode(
                source: fuente, homography: .identity,
                blind: BlindRect(x0: 0, y0: 24, x1: 64, y1: 32),
                destination: destino, commandBuffer: $0
            )
        }
        let bgr = Self.bgr(nv12: destino)
        let margen = RigConstants.panoramaBlindMarginPx
        XCTAssertGreaterThan(bgr[(10 * ancho + 30) * 3], 250, "fuera de la franja se ve")
        for y in (24 - margen)..<alto {
            XCTAssertLessThan(bgr[(y * ancho + 30) * 3 + 1], 4, "fila \(y): el código no sale")
        }
    }

    func testElColorYLaGananciaSobreUnParcheUniforme() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ReprojectKernel(context: contexto)
        let (ancho, alto) = (32, 16)
        // Un naranja de equipo, BGR, con la ganancia en el orden BGR de la referencia.
        let color: [UInt8] = [36, 106, 242]
        let fuente = try Self.nv12(bgr: Array((0..<(ancho * alto)).map { _ in color }.joined()), ancho: ancho, alto: alto)
        let destino = try Self.nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        try Self.ejecutar(contexto) {
            try kernel.encode(
                source: fuente, homography: .identity, gains: (b: 1.2, g: 1.0, r: 0.9),
                destination: destino, commandBuffer: $0
            )
        }
        let bgr = Self.bgr(nv12: destino)
        let centro = (8 * ancho + 16) * 3
        let esperado = [36 * 1.2, 106.0, 242 * 0.9]
        for c in 0..<3 {
            XCTAssertEqual(Double(bgr[centro + c]), esperado[c], accuracy: 3, "canal \(c)")
        }
    }

    func testDetrasDeLaCamaraEsNegro() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ReprojectKernel(context: contexto)
        let (ancho, alto) = (32, 16)
        let fuente = try Self.nv12(bgr: [UInt8](repeating: 200, count: ancho * alto * 3), ancho: ancho, alto: alto)
        let destino = try Self.nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        // w = −1 en todo el programa: nada cae delante de la cámara.
        try Self.ejecutar(contexto) {
            try kernel.encode(
                source: fuente, homography: Mat3(rows: [1, 0, 0, 0, 1, 0, 0, 0, -1]),
                destination: destino, commandBuffer: $0
            )
        }
        XCTAssertTrue(Self.bgr(nv12: destino).allSatisfy { $0 < 4 })
    }

    // MARK: - El programa de un caso

    private struct Caso {
        let nombre: String
        let rig: RigModel
        let vista: RectilinearView
        let frames: [CameraSide: [UInt8]]
        let tamFrame: [CameraSide: (Int, Int)]
        let ganancias: [CameraSide: (b: Double, g: Double, r: Double)]
        let costura: Double?
        let difuminado: Double
        let programa: [UInt8]
    }

    private static func pintar(_ caso: Caso, kernel: ReprojectKernel, contexto: MetalContext) throws -> [UInt8] {
        let (ancho, alto) = (caso.vista.width, caso.vista.height)
        let lados = sidesFor(rig: caso.rig, view: caso.vista).filter { caso.frames[$0] != nil }
        var partes: [CameraSide: [UInt8]] = [:]
        for lado in lados {
            let (w, h) = caso.tamFrame[lado]!
            let fuente = try nv12(bgr: caso.frames[lado]!, ancho: w, alto: h)
            let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
            try ejecutar(contexto) {
                try kernel.encode(
                    source: fuente,
                    homography: viewHomography(rig: caso.rig, view: caso.vista, side: lado),
                    gains: caso.ganancias[lado] ?? (1, 1, 1),
                    destination: destino, commandBuffer: $0
                )
            }
            partes[lado] = bgr(nv12: destino)
        }
        if lados.count == 1 { return partes[lados[0]]! }
        let pesos = pesosCostura(caso)
        var salida = [UInt8](repeating: 0, count: ancho * alto * 3)
        for i in 0..<(ancho * alto) {
            for c in 0..<3 {
                let v = pesos[i] * Double(partes[.left]![i * 3 + c])
                    + (1 - pesos[i]) * Double(partes[.right]![i * 3 + c])
                salida[i * 3 + c] = UInt8(min(max(v.rounded(), 0), 255))
            }
        }
        return salida
    }

    /// El peso de la izquierda por píxel, como render_view de la ruta GPU.
    private static func pesosCostura(_ caso: Caso) -> [Double] {
        let v = caso.vista
        let t = v.pose.matrix()
        let costura = caso.costura
            ?? (caso.rig.camera(.left).pose.yawRad + caso.rig.camera(.right).pose.yawRad) / 2
        var pesos = [Double](repeating: 0, count: v.width * v.height)
        for y in 0..<v.height {
            for x in 0..<v.width {
                let xc = (Double(x) - (Double(v.width) / 2 - 0.5)) / v.focalPx
                let yc = (Double(y) - (Double(v.height) / 2 - 0.5)) / v.focalPx
                let yaw = atan2(t[0, 0] * xc + t[0, 1] * yc + t[0, 2], t[2, 0] * xc + t[2, 1] * yc + t[2, 2])
                pesos[y * v.width + x] = min(max(0.5 - (yaw - costura) / caso.difuminado, 0), 1)
            }
        }
        return pesos
    }

    /// PSNR fuera de la rampa y dentro de ella (nil si el plano no tiene costura).
    private static func psnr(programa: [UInt8], caso: Caso) -> (Double, Double?) {
        let dosLados = sidesFor(rig: caso.rig, view: caso.vista).filter { caso.frames[$0] != nil }.count == 2
        let pesos = dosLados ? pesosCostura(caso) : [Double](repeating: 1, count: programa.count / 3)
        func luma(_ a: [UInt8], _ i: Int) -> Double {
            kb * Double(a[i * 3]) + (1 - kr - kb) * Double(a[i * 3 + 1]) + kr * Double(a[i * 3 + 2])
        }
        var (sv, nv, sr, nr) = (0.0, 0, 0.0, 0)
        for i in 0..<(programa.count / 3) {
            let d = luma(programa, i) - luma(caso.programa, i)
            if pesos[i] > 0 && pesos[i] < 1 { sr += d * d; nr += 1 } else { sv += d * d; nv += 1 }
        }
        func db(_ s: Double, _ n: Int) -> Double {
            let mse = s / Double(max(n, 1))
            return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
        }
        return (db(sv, nv), nr > 0 ? db(sr, nr) : nil)
    }

    // MARK: - NV12 BT.709 de rango limitado en la CPU

    private static let kr = 0.2126, kb = 0.0722

    private static func nv12(bgr: [UInt8], ancho: Int, alto: Int) throws -> CVPixelBuffer {
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

    private static func bgr(nv12 buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ancho = CVPixelBufferGetWidth(buffer), alto = CVPixelBufferGetHeight(buffer)
        let lumaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cromaPtr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var salida = [UInt8](repeating: 0, count: ancho * alto * 3)
        func sat(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        for y in 0..<alto {
            for x in 0..<ancho {
                let yn = (Double(lumaPtr[y * lumaStride + x]) - 16) / 219
                let cb = (Double(cromaPtr[(y / 2) * cromaStride + (x / 2) * 2]) - 128) / 224
                let cr = (Double(cromaPtr[(y / 2) * cromaStride + (x / 2) * 2 + 1]) - 128) / 224
                let r = yn + 2 * (1 - kr) * cr
                let b = yn + 2 * (1 - kb) * cb
                let g = (yn - kr * r - kb * b) / (1 - kr - kb)
                let i = (y * ancho + x) * 3
                salida[i] = sat(b); salida[i + 1] = sat(g); salida[i + 2] = sat(r)
            }
        }
        return salida
    }

    private static func ejecutar(_ contexto: MetalContext, _ cuerpo: (MTLCommandBuffer) throws -> Void) throws {
        let cb = try XCTUnwrap(contexto.queue.makeCommandBuffer())
        try cuerpo(cb)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
    }

    // MARK: - Los dorados de reprojection.json

    private static func casosRender() throws -> [Caso] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RigCoreTests/Golden/reprojection.json")
        let raiz = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let casos = try XCTUnwrap(raiz["cases"] as? [[String: Any]])
        return try casos.filter { $0["fn"] as? String == "ViewRenderer.render" }.map { caso in
            let entradas = try XCTUnwrap(caso["inputs"] as? [String: Any])
            let esperado = try XCTUnwrap(caso["expected"] as? [String: Any])
            let v = try XCTUnwrap(entradas["view"] as? [String: Any])
            var frames: [CameraSide: [UInt8]] = [:]
            var tam: [CameraSide: (Int, Int)] = [:]
            for (lado, tensor) in try XCTUnwrap(entradas["frames"] as? [String: Any]) {
                guard let t = tensor as? [String: Any] else { continue }
                let side = try XCTUnwrap(CameraSide(rawValue: lado))
                let forma = try XCTUnwrap(t["shape"] as? [Int])
                frames[side] = try bytes(t)
                tam[side] = (forma[1], forma[0])
            }
            var ganancias: [CameraSide: (b: Double, g: Double, r: Double)] = [:]
            if let g = entradas["gains"] as? [String: [Double]] {
                for (lado, valores) in g {
                    ganancias[CameraSide(rawValue: lado)!] = (valores[0], valores[1], valores[2])
                }
            }
            return Caso(
                nombre: try XCTUnwrap(caso["name"] as? String),
                rig: try RigModel.fromDictionary(try XCTUnwrap(entradas["rig"] as? [String: Any])),
                vista: try RectilinearView(
                    yawRad: numero(v["yaw_rad"]), pitchRad: numero(v["pitch_rad"]),
                    hfovRad: numero(v["hfov_rad"]),
                    width: Int(numero(v["width"])), height: Int(numero(v["height"]))
                ),
                frames: frames,
                tamFrame: tam,
                ganancias: ganancias,
                costura: entradas["seam_yaw_rad"] as? Double,
                difuminado: numero(entradas["feather_rad"]),
                programa: try bytes(try XCTUnwrap(esperado["program"] as? [String: Any]))
            )
        }
    }

    private static func numero(_ v: Any?) -> Double {
        (v as? Double) ?? Double(v as? Int ?? 0)
    }

    private static func bytes(_ tensor: [String: Any]) throws -> [UInt8] {
        XCTAssertEqual(tensor["dtype"] as? String, "u8")
        return [UInt8](try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(tensor["b64"] as? String))))
    }
}
