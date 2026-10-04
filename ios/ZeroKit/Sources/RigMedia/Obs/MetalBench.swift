// El banco de los kernels Metal (IOS-40, IOS-41, IOS-21): tiempo de GPU por fotograma
// en el iPhone, con los tamaños de verdad.
//
// - reproject: la parte de una cámara, de 4K NV12 a 1080p NV12 (objetivo ≤1,5 ms);
// - compose: las dos partes + gráfico + anuncio a NV12 1080p (≤3 ms de GPU del
//   maestro, que suma la reproyección propia y esta pasada);
// - preprocess: de 4K NV12 a la entrada 1920×576 BGRA del detector (≤0,5 ms).
//
// Se mide `gpuEndTime − gpuStartTime` de cada command buffer, que es el tiempo de la
// GPU y no el de la CPU que espera. Los búferes salen de pools precalentados, como en
// el directo; el contenido es sintético (el coste no depende de lo que se pinta).

import CoreVideo
import Foundation
import Metal
import RigCore

enum MetalBench {
    static let defaultIterations = 300
    /// Las primeras pasadas compilan pipelines y calientan cachés: no cuentan.
    static let warmup = 20

    static func run(report: inout BenchReport, progress: BenchRunner.Progress?) throws {
        let iteraciones = Int(report.params["iterations"] ?? "") ?? defaultIterations
        guard let contexto = MetalContext() else {
            throw ReprojectKernelError.pipeline("no hay Metal")
        }
        let rig = try DirectorBench.nominalRig()
        let fuente = try nv12(contexto, 3840, 2160)
        let parteA = try nv12(contexto, 1920, 1080)
        let parteB = try nv12(contexto, 1920, 1080)
        let programa = try nv12(contexto, 1920, 1080)

        // La vista que cruza la costura: el caso que más trabaja.
        let vista = try RectilinearView(yawRad: 0, pitchRad: -0.14, hfovRad: 1.1, width: 1920, height: 1080)
        let reproject = try ReprojectKernel(context: contexto)
        let h = viewHomographyToRaw(rig: rig, view: vista, side: .left)
        let franja = BlindRect(x0: 0, y0: 0, x1: 640, y1: 40)

        let compose = try ComposeProgramKernel(context: contexto)
        guard let grafico = UploadTexture(device: contexto.device, width: 1920, height: 1080),
              let premul = UploadTexture(device: contexto.device, width: 1920, height: 108),
              let inversa = UploadTexture(device: contexto.device, width: 1920, height: 108)
        else {
            throw ReprojectKernelError.texture("no se pudieron crear las texturas del gráfico")
        }
        grafico.upload(rgba: [UInt8](repeating: 128, count: 1920 * 1080 * 4), generation: 0)
        premul.upload(rgba: [UInt8](repeating: 40, count: 1920 * 108 * 4), generation: 0)
        inversa.upload(rgba: [UInt8](repeating: 200, count: 1920 * 108 * 4), generation: 0)
        let anuncio = ComposeProgramKernel.Strip(premul: premul.texture, inverse: inversa.texture)

        let banda = try BandGeometry.fromDictionary([
            "version": 1, "side": "left", "rows": [900, 2052], "input_size": [1920, 576],
            "far_split_row": NSNull(),
            "regions": [["dst": [0, 0, 1920, 576], "src": [0.0, 900.0, 3840.0, 1152.0]]],
        ])
        let preprocess = try DetectorInputBuilder(
            context: contexto, band: banda, sourceWidth: 3840, sourceHeight: 2160, upsideDown: true
        )
        guard let entradaPool = PixelBufferPool(width: 1920, height: 576, pixelFormat: kCVPixelFormatType_32BGRA, capacity: 1),
              let entrada = entradaPool.take()
        else {
            throw ReprojectKernelError.texture("no se pudo crear la entrada del detector")
        }

        let pasadas: [(String, (MTLCommandBuffer) throws -> Void)] = [
            ("gpu/reproject", { cb in
                try reproject.encode(source: fuente, homography: h, blind: franja, destination: parteA, commandBuffer: cb)
            }),
            ("gpu/compose", { cb in
                try compose.encode(
                    master: parteA, masterSide: .left, slave: parteB, view: vista,
                    seamYawRad: 0, graphic: grafico.texture, strip: anuncio,
                    destination: programa, commandBuffer: cb
                )
            }),
            ("gpu/preprocess", { cb in
                try preprocess.encode(nv12: fuente, into: entrada, commandBuffer: cb)
            }),
        ]
        var maestro: [Double] = []
        var porPasada: [String: [Double]] = [:]
        for i in 0..<(iteraciones + warmup) {
            var total = 0.0
            for (nombre, encode) in pasadas {
                guard let cb = contexto.queue.makeCommandBuffer() else {
                    throw ReprojectKernelError.pipeline("no hay command buffer")
                }
                try encode(cb)
                cb.commit()
                cb.waitUntilCompleted()
                if let error = cb.error { throw error }
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                if i >= warmup {
                    porPasada[nombre, default: []].append(ms)
                    if nombre != "gpu/preprocess" { total += ms }
                }
            }
            if i >= warmup { maestro.append(total) }
            if i % 50 == 0 {
                progress?(Double(i) / Double(iteraciones + warmup), "pasada \(i)")
            }
        }
        for (nombre, muestras) in porPasada {
            report.stagesMs[nombre] = DirectorBench.summary(muestras)
        }
        // Lo que paga el maestro por fotograma: su reproyección y la composición.
        report.stagesMs["gpu/master_total"] = DirectorBench.summary(maestro)
        report.counters["iterations"] = iteraciones
        report.params["iterations"] = "\(iteraciones)"
    }

    private static func nv12(_ contexto: MetalContext, _ ancho: Int, _ alto: Int) throws -> CVPixelBuffer {
        guard let pool = PixelBufferPool(
            width: ancho, height: alto,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, capacity: 1
        ), let buffer = pool.take() else {
            throw ReprojectKernelError.texture("no se pudo crear un NV12 de \(ancho)×\(alto)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plano in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plano)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plano) * CVPixelBufferGetHeightOfPlane(buffer, plano)
            memset(base, plano == 0 ? 120 : 128, bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
