import CoreMedia
import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// El programa del maestro (IOS-44) con partes de verdad: el esclavo las codifica con
/// VideoToolbox, el maestro las decodifica y compone. Render y composición, falsos: aquí
/// se prueba quién pinta qué con qué vista y cuándo, no los píxeles (eso es IOS-40/41).
final class MasterProgramStageTests: XCTestCase {
    private let frameMs = 1000.0 / 30.0
    private let ancho = 320
    private let alto = 180

    private final class RenderFalso: PartRendering {
        var vistas: [ViewCommand] = []
        func render(source: CVPixelBuffer, view: ViewCommand, into destination: CVPixelBuffer) throws {
            vistas.append(view)
        }
    }

    private final class ComposicionFalsa: ProgramComposing {
        var llamadas: [(master: Bool, slave: Bool, view: ViewCommand)] = []
        func compose(master: CVPixelBuffer?, slave: CVPixelBuffer?, view: ViewCommand, atRigMs: Int64, into destination: CVPixelBuffer) throws {
            llamadas.append((master != nil, slave != nil, view))
        }
    }

    private func pool() throws -> CVPixelBufferPool {
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: ancho, kCVPixelBufferHeightKey: alto,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &p)
        return try XCTUnwrap(p)
    }

    private func fotograma(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
        return try XCTUnwrap(b)
    }

    private func vista(_ t: Int64, id: UInt32, yaw: Double = 0.1, sides: [CameraSide] = [.left, .right]) -> ViewCommand {
        ViewWire.quantized(ViewCommand(
            targetRigMs: t, viewId: id, yawRad: yaw, pitchRad: 0, hfovRad: 1.0, sides: sides,
            seamYawRad: 0, featherRad: 0.02, gains: .unity
        ))
    }

    /// El esclavo de verdad: n partes, una por fotograma, con la vista del instante.
    private func partes(_ n: Int, desde t0: Int64 = 1000, claveEn: Int? = nil) throws -> [PartPacket] {
        let enc = try VideoEncoder(width: ancho, height: alto, bitrateBps: 1_000_000, viewId: 1)
        let esclavo = SlavePartStage(
            side: .right, resolver: SlaveViewResolver(frameDurationMs: frameMs),
            renderer: RenderFalso(), encoder: enc
        )
        var salida: [PartPacket] = []
        esclavo.onPart = { salida.append($0) }
        let fuente = try fotograma(pool())
        var vistas: [ViewCommand] = []
        for i in 0..<n {
            let t = t0 + Int64((Double(i) * frameMs).rounded())
            vistas.append(vista(t, id: UInt32(i), yaw: 0.1 + Double(i) * 0.01))
            esclavo.receive(views: Array(vistas.suffix(3)))
            if i == claveEn { esclavo.requestIdr() }
            esclavo.process(frame: fuente, frameRigMs: t, ptsNs: t * 1_000_000)
        }
        enc.flush()
        esclavo.drain()
        return salida
    }

    private func maestro() throws -> (MasterProgramStage, RenderFalso, ComposicionFalsa, () -> [Int64]) {
        let render = RenderFalso()
        let comp = ComposicionFalsa()
        let p = try pool()
        let stage = MasterProgramStage(
            masterSide: .left, frameDurationMs: frameMs, renderer: render, composer: comp, masterPool: p
        )
        let propio = try fotograma(p)
        var pedidos: [Int64] = []
        stage.masterFrame = { ms in pedidos.append(ms); return (propio, {}) }
        return (stage, render, comp, { pedidos })
    }

    private func esperaDecodificadas(_ stage: MasterProgramStage, _ n: Int) {
        let tope = Date().addingTimeInterval(5)
        while stage.stats.partsDecoded < n, Date() < tope {
            usleep(5_000)
            stage.collectDecoded()
        }
        XCTAssertEqual(stage.stats.partsDecoded, n)
    }

    func testDosLentesConLaVistaDeLaParteYElFotogramaDeSuInstante() throws {
        let ps = try partes(5)
        let (stage, render, comp, pedidos) = try maestro()
        ps.forEach { stage.receive(part: $0, arrivalRigMs: $0.frameRigMs + 20) }
        esperaDecodificadas(stage, 5)

        let t = ps[2].frameRigMs
        let mia = vista(t, id: 999, yaw: -0.5)
        XCTAssertNil(stage.tick(programRigMs: t, nowRigMs: t + 50, masterView: mia), "aún no es su hora")
        let salio = stage.tick(programRigMs: t, nowRigMs: t + LinkConstants.partMaxWaitMs, masterView: mia)
        XCTAssertEqual(salio, .twoLens(view: ps[2].view, slaveFrameRigMs: t))
        XCTAssertEqual(render.vistas.last, ps[2].view, "la mitad del maestro, con la vista de la parte")
        XCTAssertEqual(pedidos().last, t, "y con su fotograma del instante de la parte")
        XCTAssertEqual(comp.llamadas.last?.master, true)
        XCTAssertEqual(comp.llamadas.last?.slave, true)
        XCTAssertEqual(stage.stats.twoLensFrames, 1)
    }

    func testSinParteATiempoUnaLenteConLaVistaDelMaestro() throws {
        let (stage, render, comp, _) = try maestro()
        let mia = vista(5000, id: 1, yaw: -0.3)
        let salio = stage.tick(programRigMs: 5000, nowRigMs: 5000 + LinkConstants.partMaxWaitMs, masterView: mia)
        XCTAssertEqual(salio, .oneLens(view: mia))
        XCTAssertEqual(render.vistas, [mia])
        XCTAssertEqual(comp.llamadas.last?.slave, false)
        XCTAssertEqual(stage.stats.oneLensFrames, 1)
    }

    func testSinCamarasRepiteYDespuesSinSenal() throws {
        let (stage, _, comp, _) = try maestro()
        var salidas: [Int64] = []
        var fuentes: [ProgramSource] = []
        stage.onProgram = { _, t in salidas.append(t) }
        stage.onSourceChange = { fuentes.append($0) }
        let mia = vista(1000, id: 1)
        stage.tick(programRigMs: 1000, nowRigMs: 1000 + LinkConstants.partMaxWaitMs, masterView: mia)  // con cámara
        stage.masterFrame = { _ in nil }                                   // la cámara se para
        for k in 1...30 {
            let t = 1000 + Int64(k * 33)
            stage.tick(programRigMs: t, nowRigMs: t + LinkConstants.partMaxWaitMs, masterView: vista(t, id: UInt32(k)))
        }
        XCTAssertEqual(fuentes, [.masterOnly, .hold, .noSignal])
        XCTAssertEqual(salidas.count, 31, "el programa no se para")
        XCTAssertEqual(stage.sources.counts["hold"], 15, "medio segundo repitiendo")
        XCTAssertEqual(comp.llamadas.last?.master, false)
        XCTAssertEqual(comp.llamadas.last?.slave, false, "SIN SEÑAL: solo el gráfico")
    }

    func testSoloLaParteDelEsclavo() throws {
        let ps = try partes(3)
        let (stage, render, comp, _) = try maestro()
        stage.masterFrame = { _ in nil }
        ps.forEach { stage.receive(part: $0, arrivalRigMs: $0.frameRigMs + 10) }
        esperaDecodificadas(stage, 3)
        let t = ps[1].frameRigMs
        stage.tick(programRigMs: t, nowRigMs: t + LinkConstants.partMaxWaitMs, masterView: vista(t, id: 9))
        XCTAssertEqual(stage.sources.current, .slaveOnly)
        XCTAssertTrue(render.vistas.isEmpty)
        XCTAssertEqual(comp.llamadas.last?.slave, true)
    }

    func testUnHuecoPideIdrYNoDecodificaHastaEl() throws {
        let ps = try partes(6)
        XCTAssertTrue(ps[0].isKey)
        XCTAssertFalse(ps[3].isKey)
        let (stage, _, _, _) = try maestro()
        var pedidas: [UInt32] = []
        stage.onIdrRequest = { pedidas.append($0) }
        stage.receive(part: ps[0], arrivalRigMs: 0)
        stage.receive(part: ps[1], arrivalRigMs: 0)
        // Se pierde la 2.
        stage.receive(part: ps[3], arrivalRigMs: 0)
        stage.receive(part: ps[4], arrivalRigMs: 0)
        esperaDecodificadas(stage, 2)
        XCTAssertEqual(pedidas, [3, 4])
        XCTAssertEqual(stage.linkStats(nowRigMs: 0).lost, 1)
    }

    func testLaEdadDeLasPartesYLoQueTardaElIdr() throws {
        // La 2 se pierde y la 5 es la clave que pide el maestro.
        let ps = try partes(6, claveEn: 5)
        XCTAssertTrue(ps[5].isKey)
        let (stage, _, _, _) = try maestro()
        for i in [0, 1, 3, 4] {
            stage.receive(part: ps[i], arrivalRigMs: ps[i].frameRigMs + 40)
        }
        XCTAssertEqual(stage.partAge.total, 4)
        XCTAssertEqual(stage.partAge.percentile(0.95), 40)
        XCTAssertEqual(stage.idrRecovery.total, 0, "sin clave no se cierra el hueco")
        // La clave llega 70 ms después de la primera petición (la de la 3).
        stage.receive(part: ps[5], arrivalRigMs: ps[3].frameRigMs + 40 + 70)
        XCTAssertEqual(stage.idrRecovery.total, 1)
        XCTAssertEqual(stage.idrRecovery.percentile(0.5), 70)
    }

    func testUnEncuadreSoloDelEsclavoNoPintaLaMitadDelMaestro() throws {
        let enc = try VideoEncoder(width: ancho, height: alto, bitrateBps: 1_000_000, viewId: 1)
        let esclavo = SlavePartStage(
            side: .right, resolver: SlaveViewResolver(frameDurationMs: frameMs),
            renderer: RenderFalso(), encoder: enc
        )
        var ps: [PartPacket] = []
        esclavo.onPart = { ps.append($0) }
        let soloDerecha = vista(1000, id: 1, sides: [.right])
        esclavo.receive(views: [soloDerecha])
        esclavo.process(frame: try fotograma(pool()), frameRigMs: 1000, ptsNs: 0)
        enc.flush()
        esclavo.drain()
        let (stage, render, comp, _) = try maestro()
        stage.receive(part: ps[0], arrivalRigMs: 1010)
        esperaDecodificadas(stage, 1)
        stage.tick(programRigMs: 1000, nowRigMs: 1000 + LinkConstants.partMaxWaitMs, masterView: vista(1000, id: 2))
        XCTAssertTrue(render.vistas.isEmpty)
        XCTAssertEqual(comp.llamadas.last?.master, false)
        XCTAssertEqual(comp.llamadas.last?.slave, true)
    }
}
