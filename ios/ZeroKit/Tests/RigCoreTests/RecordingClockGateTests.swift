// La puerta del reloj de la 4K (RecordingClockGate): el esclavo de SPK-04 del 2026-10-11,
// los saltos a mitad de grabación, el relevo y el audio.

import RigCore
import XCTest

final class RecordingClockGateTests: XCTestCase {
    /// Un fotograma a 30 fps, en ns.
    private let frameNs: Int64 = 33_333_333
    /// El host del 16 Pro al arrancar la pasada, en ns (un móvil encendido hace días).
    private let host0: Int64 = 412_345_000_000_000
    /// La distancia entre los relojes de los dos iPhone de la pasada, en ns.
    private let salto: Int64 = 591_898_000_000_000

    /// El caso medido: ~2,3 s sin estimación (desfase 0) y luego el desfase de verdad. La
    /// 4K empieza con la estimación y dura lo que se grabó, no 592 497 s.
    func testElEsclavoNoAbreLaSesionHastaTenerReloj() {
        var gate = RecordingClockGate()
        var sellos: [Int64] = []
        for n in 0..<(70 + 300) {
            let host = host0 + Int64(n) * frameNs
            let conReloj = n >= 70
            let d = gate.video(hostNs: host, offsetNs: conReloj ? salto : 0,
                               clock: conReloj ? .estimated : .waiting)
            switch d {
            case .waitForClock: XCTAssertFalse(conReloj)
            case .startSession: XCTAssertEqual(n, 70); sellos.append(host + salto)
            case .append: sellos.append(host + salto)
            default: XCTFail("fotograma \(n): \(d)")
            }
        }
        XCTAssertEqual(gate.framesWaitingForClock, 70)
        XCTAssertEqual(gate.segmentsFromClockJump, 0)
        XCTAssertEqual(gate.sessionsWithoutClock, 0)
        XCTAssertEqual(sellos.count, 300)
        XCTAssertEqual(Double(sellos.last! - sellos.first!) / 1e9, 299.0 / 30.0, accuracy: 1e-3,
                       "el fichero dura lo grabado")
    }

    func testElMaestroYElMovilSoloGrabanDesdeElPrimerFotograma() {
        for estado in [RecordingClockState.reference, .unlinked] {
            var gate = RecordingClockGate()
            XCTAssertEqual(gate.video(hostNs: host0, offsetNs: 0, clock: estado), .startSession)
            XCTAssertEqual(gate.video(hostNs: host0 + frameNs, offsetNs: 0, clock: estado), .append)
            XCTAssertEqual(gate.framesWaitingForClock, 0)
            XCTAssertTrue(gate.sessionOpen)
        }
    }

    /// Con la sesión abierta, el estado del reloj ya no se mira: solo el desfase.
    func testConLaSesionAbiertaNoSeEvaluaElReloj() {
        var gate = RecordingClockGate()
        _ = gate.video(hostNs: host0, offsetNs: 0, clock: .reference)
        var evaluado = false
        func estado() -> RecordingClockState { evaluado = true; return .waiting }
        XCTAssertEqual(gate.video(hostNs: host0 + frameNs, offsetNs: 0, clock: estado()), .append)
        XCTAssertFalse(evaluado)
    }

    /// Un salto mayor que el umbral, en cualquier sentido, cierra el segmento; una
    /// corrección del reloj, no.
    func testUnSaltoDelDesfaseCierraElSegmento() {
        let umbral = RecordingPolicy.clockJumpSegmentNs
        XCTAssertEqual(umbral, 100_000_000)
        for (cambio, corta) in [(Int64(5_000_000), false), (umbral, false), (umbral + 1, true),
                                (-umbral - 1, true), (salto, true), (-salto, true)] {
            var gate = RecordingClockGate()
            let base: Int64 = 7_000_000_000
            XCTAssertEqual(gate.video(hostNs: host0, offsetNs: base, clock: .estimated), .startSession)
            let d = gate.video(hostNs: host0 + frameNs, offsetNs: base + cambio, clock: .estimated)
            if corta {
                XCTAssertEqual(d, .rollSegment(startsSession: true), "cambio \(cambio)")
                XCTAssertEqual(gate.segmentsFromClockJump, 1)
                XCTAssertEqual(gate.video(hostNs: host0 + 2 * frameNs, offsetNs: base + cambio, clock: .estimated),
                               .append, "el segmento nuevo sigue con su desfase")
            } else {
                XCTAssertEqual(d, .append, "cambio \(cambio)")
                XCTAssertEqual(gate.segmentsFromClockJump, 0)
            }
        }
    }

    /// 90 min con 60 ppm de deriva (324 ms en total): ni un corte, todo dentro.
    func testLaDerivaNoCortaNada() {
        var gate = RecordingClockGate()
        let fotogramas = 90 * 60 * 30
        var dentro = 0
        for n in 0..<fotogramas {
            let host = host0 + Int64(n) * frameNs
            let desfase = salto + Int64(Double(Int64(n) * frameNs) * 60e-6)
            switch gate.video(hostNs: host, offsetNs: desfase, clock: .estimated) {
            case .startSession, .append: dentro += 1
            default: XCTFail("fotograma \(n)")
            }
        }
        XCTAssertEqual(dentro, fotogramas)
        XCTAssertEqual(gate.segmentsFromClockJump, 0)
        XCTAssertEqual(gate.framesOutOfOrder, 0)
    }

    /// Una corrección de 50 ms hacia atrás (bajo el umbral) deja el sello del siguiente
    /// fotograma detrás del último: se tira en vez de romper el escritor.
    func testUnaCorreccionHaciaAtrasTiraLosSellosQueNoAvanzan() {
        var gate = RecordingClockGate()
        XCTAssertEqual(gate.video(hostNs: host0, offsetNs: salto, clock: .estimated), .startSession)
        XCTAssertEqual(gate.video(hostNs: host0 + frameNs, offsetNs: salto, clock: .estimated), .append)
        let atras = salto - 50_000_000
        XCTAssertEqual(gate.video(hostNs: host0 + 2 * frameNs, offsetNs: atras, clock: .estimated), .outOfOrder)
        XCTAssertEqual(gate.video(hostNs: host0 + 3 * frameNs, offsetNs: atras, clock: .estimated), .append)
        XCTAssertEqual(gate.framesOutOfOrder, 1)
        XCTAssertEqual(gate.segmentsFromClockJump, 0)
    }

    /// Sin enlace en 30 s, el esclavo graba con su host; cuando llega la estimación, el
    /// salto abre un segmento con el reloj del soporte.
    func testLaEsperaVenceYLaEstimacionAbreOtroSegmento() {
        var gate = RecordingClockGate()
        let espera = Int(RecordingPolicy.clockWaitMaxNs / frameNs) + 1
        var n = 0
        while gate.video(hostNs: host0 + Int64(n) * frameNs, offsetNs: 0, clock: .waiting) == .waitForClock {
            n += 1
        }
        XCTAssertEqual(n, espera, "abre al vencer los 30 s")
        XCTAssertEqual(gate.framesWaitingForClock, Int64(espera))
        XCTAssertEqual(gate.sessionsWithoutClock, 1)
        XCTAssertEqual(gate.video(hostNs: host0 + Int64(n + 1) * frameNs, offsetNs: 0, clock: .waiting), .append)
        XCTAssertEqual(gate.video(hostNs: host0 + Int64(n + 2) * frameNs, offsetNs: salto, clock: .estimated),
                       .rollSegment(startsSession: true))
        XCTAssertEqual(gate.segmentsFromClockJump, 1)
    }

    /// El maestro que graba pasa a esclavo (vuelve tras un relevo) y le llega una muestra
    /// suelta de otro dominio: cierra el segmento y el nuevo espera a la estimación.
    func testEnUnRelevoElSegmentoNuevoEsperaAlReloj() {
        var gate = RecordingClockGate()
        XCTAssertEqual(gate.video(hostNs: host0, offsetNs: 0, clock: .reference), .startSession)
        XCTAssertEqual(gate.video(hostNs: host0 + frameNs, offsetNs: -salto, clock: .waiting),
                       .rollSegment(startsSession: false))
        XCTAssertEqual(gate.video(hostNs: host0 + 2 * frameNs, offsetNs: -salto, clock: .waiting), .waitForClock)
        XCTAssertEqual(gate.video(hostNs: host0 + 3 * frameNs, offsetNs: -salto, clock: .estimated), .startSession)
        XCTAssertEqual(gate.segmentsFromClockJump, 1)
        XCTAssertEqual(gate.framesWaitingForClock, 2)
    }

    /// El audio solo entra con sesión abierta y con el desfase del segmento: la trama que
    /// llega entre el salto y el fotograma que corta se tira.
    func testElAudioVaConElSegmentoDelVideo() {
        var gate = RecordingClockGate()
        XCTAssertFalse(gate.audio(offsetNs: 0), "sin sesión no entra")
        _ = gate.video(hostNs: host0, offsetNs: 0, clock: .reference)
        XCTAssertTrue(gate.audio(offsetNs: 3_000_000))
        XCTAssertFalse(gate.audio(offsetNs: salto), "el dominio nuevo, antes de que corte el vídeo")
        XCTAssertEqual(gate.audioDroppedOnJump, 1)
        _ = gate.video(hostNs: host0 + frameNs, offsetNs: salto, clock: .estimated)
        XCTAssertTrue(gate.audio(offsetNs: salto), "ya en el segmento nuevo")
        XCTAssertFalse(gate.audio(offsetNs: 0))
        XCTAssertEqual(gate.audioDroppedOnJump, 2)
    }

    /// Un segmento abierto desde fuera (volver de un corte) empieza sin sesión, y los
    /// contadores siguen.
    func testUnSegmentoAbiertoDesdeFueraEmpiezaSinSesion() {
        var gate = RecordingClockGate()
        _ = gate.video(hostNs: host0, offsetNs: 0, clock: .waiting)
        _ = gate.video(hostNs: host0 + frameNs, offsetNs: salto, clock: .estimated)
        XCTAssertTrue(gate.sessionOpen)
        gate.segmentOpened()
        XCTAssertFalse(gate.sessionOpen)
        XCTAssertFalse(gate.audio(offsetNs: salto))
        XCTAssertEqual(gate.video(hostNs: host0 + 9 * frameNs, offsetNs: salto, clock: .estimated), .startSession)
        XCTAssertEqual(gate.framesWaitingForClock, 1)
    }
}
