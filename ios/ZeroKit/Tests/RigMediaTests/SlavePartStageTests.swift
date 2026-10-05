import CoreMedia
import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// La parte del esclavo (IOS-43): qué vista usa, cuándo manda `no_part`, el IDR a
/// petición y los SPS/PPS en banda, con un render falso y el codificador de verdad.
final class SlavePartStageTests: XCTestCase {
    private let frameMs = 1000.0 / 30.0

    private final class RenderFalso: PartRendering {
        var vistas: [ViewCommand] = []
        var falla = false
        func render(source: CVPixelBuffer, view: ViewCommand, into destination: CVPixelBuffer) throws {
            if falla { throw ReprojectKernelError.pipeline("falla a propósito") }
            vistas.append(view)
        }
    }

    private func vista(_ t: Int64, id: UInt32, sides: [CameraSide] = [.left, .right]) -> ViewCommand {
        ViewWire.quantized(ViewCommand(
            targetRigMs: t, viewId: id, yawRad: 0.1, pitchRad: 0, hfovRad: 1.0, sides: sides,
            seamYawRad: 0, featherRad: 0.02, gains: .unity
        ))
    }

    private func fuente() throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b
        )
        return try XCTUnwrap(b)
    }

    private func etapa(
        _ render: RenderFalso, _ encoder: VideoEncoder, side: CameraSide = .right
    ) -> (SlavePartStage, () -> [PartPacket], () -> [NoPartPacket]) {
        let s = SlavePartStage(
            side: side, resolver: SlaveViewResolver(frameDurationMs: frameMs),
            renderer: render, encoder: encoder
        )
        var partes: [PartPacket] = []
        var nadas: [NoPartPacket] = []
        s.onPart = { partes.append($0) }
        s.onNoPart = { nadas.append($0) }
        return (s, { partes }, { nadas })
    }

    func testSinVistaNoMandaNadaYConOtroLadoMandaNoPart() throws {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 1)
        let render = RenderFalso()
        let (s, partes, nadas) = etapa(render, enc)
        let f = try fuente()
        s.process(frame: f, frameRigMs: 1000, ptsNs: 0)
        XCTAssertEqual(s.stats.withoutView, 1)
        s.receive(views: [vista(1000, id: 1, sides: [.left]), vista(1033, id: 2, sides: [.left])])
        s.process(frame: f, frameRigMs: 1033, ptsNs: 33)
        XCTAssertEqual(nadas(), [NoPartPacket(frameRigMs: 1033, viewId: 2)])
        XCTAssertTrue(partes().isEmpty)
        XCTAssertTrue(render.vistas.isEmpty, "sin su lado no pinta nada")
    }

    func testPartesConSuVistaSeqSeguidoYElPrimerIdrConSpsPps() throws {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 1)
        let render = RenderFalso()
        let (s, partes, _) = etapa(render, enc)
        let f = try fuente()
        var vistas: [ViewCommand] = []
        for i in 0..<10 {
            let t = Int64(1000 + Double(i) * frameMs)
            vistas.append(vista(t, id: UInt32(i)))
            s.receive(views: Array(vistas.suffix(LinkConstants.viewHistory)))
            s.process(frame: f, frameRigMs: t, ptsNs: Int64(i) * 33_333_333)
        }
        enc.flush()
        s.drain()
        let p = partes()
        XCTAssertEqual(p.count, 10)
        XCTAssertEqual(p.map(\.partSeq), Array(0..<10))
        XCTAssertTrue(p[0].isKey)
        let tipos = NalUnits.types(inAvcc: p[0].accessUnit)
        XCTAssertTrue(tipos.contains(7) && tipos.contains(8) && tipos.contains(5), "\(tipos)")
        XCTAssertFalse(p[1].isKey)
        XCTAssertEqual(p.map(\.view.viewId), Array(0..<10), "cada parte, con la vista que usó")
        XCTAssertEqual(render.vistas.map(\.viewId), Array(0..<10))
        XCTAssertFalse(p.contains(where: \.extrapolated))
    }

    func testLaPeticionDeIdrSaleEnElSiguienteFotograma() throws {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 1)
        let (s, partes, _) = etapa(RenderFalso(), enc)
        let f = try fuente()
        var vistas: [ViewCommand] = []
        func fotograma(_ i: Int) {
            let t = Int64(1000 + Double(i) * frameMs)
            vistas.append(vista(t, id: UInt32(i)))
            s.receive(views: Array(vistas.suffix(3)))
            s.process(frame: f, frameRigMs: t, ptsNs: Int64(i) * 33_333_333)
            enc.flush()
            s.drain()
        }
        (0..<5).forEach(fotograma)
        s.requestIdr()
        fotograma(5)
        let p = partes()
        XCTAssertTrue(p.last!.isKey, "el fotograma de después de la petición es IDR")
        XCTAssertEqual(p.filter(\.isKey).count, 2)
        XCTAssertEqual(s.stats.idrRequests, 1)
    }

    func testSinVistaNuevaExtrapolaYLoMarca() throws {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 1)
        let (s, partes, _) = etapa(RenderFalso(), enc)
        let f = try fuente()
        s.receive(views: [vista(1000, id: 1), vista(1033, id: 2)])
        // 100 ms más tarde que la última vista: extrapola.
        s.process(frame: f, frameRigMs: 1133, ptsNs: 0)
        enc.flush()
        s.drain()
        XCTAssertEqual(partes().first?.extrapolated, true)
    }

    func testUnRenderQueFallaSeCuentaYNoSaleParte() throws {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 1)
        let render = RenderFalso()
        render.falla = true
        let (s, partes, _) = etapa(render, enc)
        s.receive(views: [vista(1000, id: 1)])
        s.process(frame: try fuente(), frameRigMs: 1000, ptsNs: 0)
        enc.flush()
        s.drain()
        XCTAssertEqual(s.stats.renderFailures, 1)
        XCTAssertTrue(partes().isEmpty)
    }
}
