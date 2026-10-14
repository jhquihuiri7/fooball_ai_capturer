import XCTest

@testable import RigCore

/// El eje del AAC del programa (IOS-54): sigue el sello del micro aunque su reloj derive,
/// rellena los huecos, recorta los solapes y salta si el reloj del soporte salta.
final class AudioTimelineTests: XCTestCase {
    private let rate = 48_000
    private let buf = 1024

    /// Mete un búfer como lo haría el codificador: lo que dice `place` y lo que entra.
    @discardableResult
    private func meter(_ eje: inout AudioTimeline, ms: Double, frames: Int) -> AudioTimeline.Placement {
        let p = eje.place(rigMs: ms, frames: frames)
        switch p {
        case .asIs, .reanchored: eje.advance(by: frames)
        case .repeatFirst: eje.advance(by: frames + 1)
        case .dropFirst: eje.advance(by: frames - 1)
        case let .silenceBefore(n): eje.advance(by: n + frames)
        case let .dropLeading(n): eje.advance(by: frames - n)
        }
        return p
    }

    func testElPrimerBuferFijaElInstanteYElCebadoVaDelante() throws {
        var eje = AudioTimeline(sampleRate: rate)
        XCTAssertFalse(eje.isAnchored)
        XCTAssertNil(eje.rigMs(ofSample: 0))
        XCTAssertEqual(meter(&eje, ms: 5000, frames: buf), .asIs)
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: 0)), 5000)
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: 48)), 5001, accuracy: 1e-9)
        // 2112 muestras de cebado delante de la primera: 44 ms antes.
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: -2112)), 4956, accuracy: 1e-9)
    }

    func testSeguidosYConTembladeraDentroDeLaToleranciaVanTalCual() {
        var eje = AudioTimeline(sampleRate: rate)
        let paso = 1000 * Double(buf) / Double(rate)
        for k in 0..<1000 {
            let temblor = (k % 2 == 0 ? 0.4 : -0.4)  // ms, menos que la tolerancia
            XCTAssertEqual(meter(&eje, ms: 100 + Double(k) * paso + temblor, frames: buf), .asIs)
        }
        XCTAssertEqual(eje.nudges, 0)
        XCTAssertEqual(eje.silenceSamples, 0)
    }

    /// La deriva del reloj del micro (medida: ~45 ppm; aquí ±150 ppm en 90 min) se absorbe
    /// muestra a muestra: el eje nunca se separa del sello más de la tolerancia y algo.
    func testLaDerivaDelMicroSeAbsorbeMuestraAMuestra() {
        for ppm in [150.0, -150.0] {
            var eje = AudioTimeline(sampleRate: rate)
            let pasoHost = 1000 * Double(buf) / Double(rate) * (1 - ppm * 1e-6)
            var peor = 0.0
            let buferes = 90 * 60 * rate / buf
            for k in 0..<buferes {
                let sello = 1000 + Double(k) * pasoHost
                let p = meter(&eje, ms: sello, frames: buf)
                XCTAssertTrue([.asIs, .repeatFirst, .dropFirst].contains(p), "solo correcciones finas: \(p)")
                // Dónde quedó la primera muestra de este búfer en el eje.
                let enEje = eje.rigMs(ofSample: eje.samples - buf)!
                peor = max(peor, abs(enEje - sello))
            }
            XCTAssertLessThan(peor, AudioSync.toleranceMs + 0.05, "\(ppm) ppm")
            let esperadas = Double(buferes * buf) * abs(ppm) * 1e-6
            XCTAssertEqual(Double(eje.nudges), esperadas, accuracy: esperadas * 0.02 + 50, "\(ppm) ppm")
            XCTAssertEqual(eje.reanchors, 0)
        }
    }

    func testUnHuecoDelMicroSeRellenaConSilencio() {
        var eje = AudioTimeline(sampleRate: rate)
        meter(&eje, ms: 0, frames: buf)
        // El siguiente llega 300 ms tarde (se perdieron búferes): 14 400 muestras de silencio.
        let llega = 1000 * Double(buf) / Double(rate) + 300
        XCTAssertEqual(meter(&eje, ms: llega, frames: buf), .silenceBefore(14_400))
        XCTAssertEqual(eje.rigMs(ofSample: eje.samples - buf)!, llega, accuracy: 1e-6)
        XCTAssertEqual(eje.silenceSamples, 14_400)
    }

    func testUnSolapeSeRecortaAunqueSeaMasLargoQueElBufer() {
        var eje = AudioTimeline(sampleRate: rate)
        meter(&eje, ms: 0, frames: buf)
        // Llega 15 ms antes de lo que toca: se tiran 720 muestras.
        let toca = 1000 * Double(buf) / Double(rate)
        XCTAssertEqual(meter(&eje, ms: toca - 15, frames: buf), .dropLeading(720))
        XCTAssertEqual(eje.rigMs(ofSample: eje.samples)!, toca - 15 + 1000 * Double(buf) / Double(rate), accuracy: 1e-6)
        // 40 ms antes: más que el búfer entero (21,3 ms). Se tira todo y el resto, en el siguiente.
        let ahora = eje.rigMs(ofSample: eje.samples)!
        XCTAssertEqual(meter(&eje, ms: ahora - 40, frames: buf), .dropLeading(buf))
        XCTAssertEqual(meter(&eje, ms: ahora - 40 + 1000 * Double(buf) / Double(rate), frames: buf), .dropLeading(896))
        XCTAssertEqual(eje.droppedSamples, 720 + buf + 896)
    }

    func testUnSaltoDelRelojReanclaYLasMuestrasViejasConservanSuInstante() throws {
        var eje = AudioTimeline(sampleRate: rate)
        meter(&eje, ms: 0, frames: buf)
        let corte = eje.samples
        XCTAssertEqual(meter(&eje, ms: 60_000, frames: buf), .reanchored)
        XCTAssertEqual(eje.reanchors, 1)
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: corte)), 60_000)
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: corte - 1)), 1000 * Double(corte - 1) / Double(rate), accuracy: 1e-9)
        // Hacia atrás también: el soporte retrocedió 5 s.
        let siguiente = try XCTUnwrap(eje.rigMs(ofSample: eje.samples))
        XCTAssertEqual(meter(&eje, ms: siguiente - 5000, frames: buf), .reanchored)
        XCTAssertEqual(eje.reanchors, 2)
        // Sellada una trama que empieza antes del segundo salto, solo sobra la primera ancla.
        XCTAssertEqual(eje.anchorCount, 3)
        eje.prune(before: corte + buf - 1)
        XCTAssertEqual(eje.anchorCount, 2)
        XCTAssertEqual(try XCTUnwrap(eje.rigMs(ofSample: corte)), 60_000)
    }

    func testElVigilantePideSilencioSoloSiElEjeSeQuedaAtras() {
        var eje = AudioTimeline(sampleRate: rate)
        // Sin micro todavía: el primer aviso fija el instante y no pide nada.
        XCTAssertEqual(eje.silence(until: 1000), 0)
        XCTAssertTrue(eje.isAnchored)
        XCTAssertEqual(eje.silence(until: 1100), 4800)
        eje.advance(by: 4800)
        XCTAssertEqual(eje.silence(until: 1100), 0, "ya está")
        XCTAssertEqual(eje.silence(until: 1050), 0, "el eje va por delante")
        // Un vigilante que no corrió en 3 s: se reancla en vez de meter 3 s de golpe.
        XCTAssertEqual(eje.silence(until: 4200), 0)
        XCTAssertEqual(eje.reanchors, 1)
        XCTAssertEqual(eje.rigMs(ofSample: eje.samples)!, 4200)
        XCTAssertEqual(eje.silenceSamples, 4800)
    }

    /// El relleno más largo cabe en la cola de salida del codificador (64 tramas de 1024).
    func testElRellenoMasLargoCabeEnLaColaDelCodificador() {
        let tramas = AudioSync.maxFillMs / 1000 * Double(rate) / Double(buf)
        XCTAssertLessThan(tramas, 64)
        XCTAssertLessThan(AudioSync.hardResyncMs, 20, "por debajo del ±20 ms del A/V")
    }
}
