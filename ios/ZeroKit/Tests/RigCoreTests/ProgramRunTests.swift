import XCTest

@testable import RigCore

/// EMITIR en la arquitectura B y el banco split, con los mismos ajustes (IOS-58).
final class ProgramRunTests: XCTestCase {
    // MARK: - ProgramRunConfig

    func testTheBenchReadsItsEnvironmentAsBefore() {
        let c = ProgramRunConfig.bench(environment: [
            "RIG_SPLIT_S": "90", "RIG_SPLIT_DIRECTOR": "1", "RIG_SPLIT_PUBLISH": "1",
            "RIG_SPLIT_RECORD_4K": "1", "RIG_DETECT": "x.mlpackage", "RIG_LINK_INTERFACE": "wifi",
        ])
        XCTAssertEqual(c.purpose, .bench)
        XCTAssertEqual(c.durationS, 90)
        XCTAssertTrue(c.director)
        XCTAssertTrue(c.publish)
        XCTAssertTrue(c.record4K)
        XCTAssertEqual(c.detectorPackage, "x.mlpackage")
        XCTAssertEqual(c.partBitrateBps, LinkConstants.partBitrateWifiBps)
        XCTAssertTrue(c.benchFiles)
    }

    func testAnEmptyBenchIsTheTenMinuteSweepByCable() {
        let c = ProgramRunConfig.bench(environment: [:])
        XCTAssertEqual(c.durationS, 600)
        XCTAssertFalse(c.director)
        XCTAssertFalse(c.publish)
        XCTAssertFalse(c.record4K)
        XCTAssertNil(c.detectorPackage)
        XCTAssertEqual(c.partBitrateBps, LinkConstants.partBitrateEthernetBps)
    }

    func testTheBenchPartBitrateCanBeForced() {
        let c = ProgramRunConfig.bench(environment: ["RIG_SPLIT_PART_MBPS": "15", "RIG_LINK_INTERFACE": "wifi"])
        XCTAssertEqual(c.partBitrateBps, 15_000_000)
    }

    func testProductionDirectsPublishesAndNeverEndsOnItsOwn() {
        let c = ProgramRunConfig.production(medium: .aware, detectorPackage: "p.mlpackage")
        XCTAssertEqual(c.purpose, .production)
        XCTAssertEqual(c.durationS, .infinity)
        XCTAssertTrue(c.director)
        XCTAssertTrue(c.publish)
        // La 4K de la emisión va por CaptureHostApi.start, con la reserva del partido.
        XCTAssertFalse(c.record4K)
        XCTAssertFalse(c.benchFiles)
        XCTAssertEqual(c.detectorPackage, "p.mlpackage")
        XCTAssertEqual(c.partBitrateBps, LinkMedium.aware.partBitrateBps)
        XCTAssertNil(ProgramRunConfig.production(medium: .wifi, detectorPackage: nil).detectorPackage)
        XCTAssertFalse(c.singleCamera, "con dos móviles, el programa de siempre")
    }

    func testOneCameraIsTheSameEmitirWithoutAPartner() {
        // «Una cámara (sin pareja)», 2026-10-15: lo mismo que EMITIR, de una sola lente y tal
        // cual (enmienda del ADR 0025): sin director, la lente entera.
        let c = ProgramRunConfig.single(detectorPackage: "p.mlpackage")
        XCTAssertTrue(c.singleCamera)
        XCTAssertEqual(c.purpose, .production)
        XCTAssertEqual(c.durationS, .infinity)
        XCTAssertFalse(c.director, "tal cual: la lente entera, sin director")
        XCTAssertTrue(c.publish)
        XCTAssertFalse(c.record4K)
        XCTAssertFalse(c.benchFiles)
        XCTAssertEqual(c.detectorPackage, "p.mlpackage")
        XCTAssertEqual(c.partBitrateBps, ProgramRunConfig.noPartBitrateBps)
        XCTAssertNil(c.ladderForce, "EMITIR deja la escalera a sus sensores")
        // El banco no lo es nunca: su entorno no tiene cómo pedirlo.
        XCTAssertFalse(ProgramRunConfig.bench(environment: ["RIG_LINK_INTERFACE": "aware"]).singleCamera)
    }

    // MARK: - La salida del programa (IOS-99)

    func testTheRigAlwaysGoesOutAt1080p() {
        XCTAssertEqual(ProgramRunConfig.production(medium: .aware, detectorPackage: nil).output, .hd1080)
        XCTAssertEqual(ProgramRunConfig.bench(environment: [:]).output, .hd1080)
        XCTAssertEqual(ProgramRunConfig.single(detectorPackage: nil).output, .hd1080, "1080p de partida")
        XCTAssertEqual(ProgramRunConfig.single(detectorPackage: nil, output: .hd720).output, .hd720)
        // 2026-10-30: el zoom de «Una cámara»; la lente entera (0,5×) de partida.
        XCTAssertEqual(ProgramRunConfig.single(detectorPackage: nil).singleZoom, FullLensView.fullLensZoom)
        XCTAssertEqual(ProgramRunConfig.single(detectorPackage: nil, zoom: 2).singleZoom, 2)
    }

    func testTheOutputsAre16By9AndNeverEnlargeTheComposition() {
        for salida in ProgramOutput.allCases {
            XCTAssertEqual(salida.width * 9, salida.height * 16, salida.rawValue)
            XCTAssertLessThanOrEqual(salida.width, ProgramOutput.hd1080.width)
        }
        XCTAssertEqual(ProgramOutput.hd720.width, 1280)
        XCTAssertEqual(ProgramOutput.hd720.height, 720)
    }

    func testThe720pCeilingKeepsTheBitsPerPixelOf1080p() {
        func porPixel(_ s: ProgramOutput) -> Double { Double(s.maximumBps) / Double(s.width * s.height) }
        XCTAssertGreaterThanOrEqual(porPixel(.hd720), porPixel(.hd1080))
        XCTAssertLessThan(ProgramOutput.hd720.maximumBps, ProgramOutput.hd1080.maximumBps)
        XCTAssertGreaterThanOrEqual(ProgramOutput.hd720.maximumBps, AdaptiveRate.minimumBps)
    }

    // MARK: - LinkChoice

    func testWithoutEnvironmentTheScreenDecides() {
        XCTAssertEqual(LinkChoice.resolve(environment: [:], requested: .network(.aware)), .network(.aware))
        XCTAssertEqual(LinkChoice.resolve(environment: [:], requested: .multipeer), .multipeer)
        // RIG_LINK_INTERFACE sola no cambia nada: hace falta RIG_LINK_MULTIPEER=0, como antes.
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_INTERFACE": "wifi"], requested: .multipeer),
                       .multipeer)
    }

    func testOneCameraIsAScreenChoiceAndTheBenchEnvironmentStillWins() {
        XCTAssertEqual(LinkChoice.resolve(environment: [:], requested: .single), .single)
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_SECRET": "x"], requested: .single), .single)
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_MULTIPEER": "0", "RIG_LINK_INTERFACE": "aware"],
                                          requested: .single), .network(.aware))
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_MULTIPEER": "1"], requested: .single), .multipeer)
    }

    func testTheBenchEnvironmentWins() {
        let banco = ["RIG_LINK_MULTIPEER": "0", "RIG_LINK_INTERFACE": "wifi"]
        XCTAssertEqual(LinkChoice.resolve(environment: banco, requested: .multipeer), .network(.wifi))
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_MULTIPEER": "0"], requested: .network(.aware)),
                       .network(.ethernet))
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_MULTIPEER": "1"], requested: .network(.wifi)),
                       .multipeer)
        XCTAssertNil(LinkChoice.resolve(environment: ["RIG_LINK_MULTIPEER": "0", "RIG_LINK_INTERFACE": "wlan"],
                                        requested: .network(.wifi)))
    }

    // MARK: - RigSecretSource

    private let s1 = Data(repeating: 1, count: 32).base64EncodedString()
    private let s2 = Data(repeating: 2, count: 32).base64EncodedString()

    func testTheEnvironmentSecretIsUsedAndKept() {
        var guardado: [String] = []
        let s = RigSecretSource.resolve(environment: s1, stored: nil) { guardado.append($0) }
        XCTAssertEqual(s, Data(repeating: 1, count: 32))
        XCTAssertEqual(guardado, [s1])
        // Otro en el entorno sustituye al guardado; el mismo no se vuelve a escribir.
        guardado = []
        XCTAssertEqual(RigSecretSource.resolve(environment: s2, stored: s1) { guardado.append($0) },
                       Data(repeating: 2, count: 32))
        XCTAssertEqual(guardado, [s2])
        guardado = []
        _ = RigSecretSource.resolve(environment: s1, stored: s1) { guardado.append($0) }
        XCTAssertEqual(guardado, [])
    }

    func testWithoutEnvironmentTheKeptSecretOpensTheLink() {
        var guardado: [String] = []
        XCTAssertEqual(RigSecretSource.resolve(environment: nil, stored: s1) { guardado.append($0) },
                       Data(repeating: 1, count: 32))
        XCTAssertEqual(guardado, [])
        XCTAssertNil(RigSecretSource.resolve(environment: nil, stored: nil) { _ in })
        XCTAssertNil(RigSecretSource.resolve(environment: nil, stored: "%%") { _ in })
    }

    func testABadEnvironmentSecretFailsInsteadOfFallingBack() {
        var guardado: [String] = []
        XCTAssertNil(RigSecretSource.resolve(environment: "no es base64", stored: s1) { guardado.append($0) })
        XCTAssertNil(RigSecretSource.resolve(environment: "", stored: s1) { guardado.append($0) })
        XCTAssertEqual(guardado, [])
    }

    // MARK: - ControlKeySource (Bug A, 2026-10-21)

    private struct KeychainRoto: Error {}

    func testWithTheRigSecretTheControlKeyIsTheRigSecret() {
        var leido = false
        let k = ControlKeySource.resolve(
            rig: Data(repeating: 1, count: 32),
            cached: .init(secret: Data(repeating: 9, count: 32), origin: .device),
            stored: { leido = true; return .success(nil) }, save: { _ in XCTFail("no guarda"); return true }
        )
        XCTAssertEqual(k, .init(secret: Data(repeating: 1, count: 32), origin: .rig))
        XCTAssertFalse(leido, "con S no se mira el secreto propio")
    }

    func testWithoutTheRigSecretTheDeviceSecretIsCreatedOnceAndKept() {
        var guardado: [String] = []
        let nuevo = ControlKeySource.resolve(
            rig: nil, cached: nil, stored: { .success(nil) },
            generate: { Data(repeating: 7, count: ControlKeySource.deviceSecretBytes) },
            save: { guardado.append($0); return true }
        )
        XCTAssertEqual(nuevo, .init(secret: Data(repeating: 7, count: 32), origin: .device))
        XCTAssertEqual(guardado, [Data(repeating: 7, count: 32).base64EncodedString()])
        // La siguiente vez (otra app abierta) sale del Keychain y no se crea otra.
        let otraVez = ControlKeySource.resolve(
            rig: nil, cached: nil, stored: { .success(guardado[0]) },
            generate: { XCTFail("no crea otra"); return Data() }, save: { _ in XCTFail("no guarda"); return true }
        )
        XCTAssertEqual(otraVez, nuevo)
        // En el mismo proceso, la ya resuelta, sin leer el Keychain.
        let enMemoria = ControlKeySource.resolve(
            rig: nil, cached: nuevo, stored: { XCTFail("no lee"); return .success(nil) },
            save: { _ in XCTFail("no guarda"); return true }
        )
        XCTAssertEqual(enMemoria, nuevo)
    }

    func testABrokenKeychainGivesAKeyThatIsNotSavedOverTheOldOne() {
        let k = ControlKeySource.resolve(
            rig: nil, cached: nil, stored: { .failure(KeychainRoto()) },
            generate: { Data(repeating: 3, count: 32) }, save: { _ in XCTFail("no pisa"); return true }
        )
        XCTAssertEqual(k, .init(secret: Data(repeating: 3, count: 32), origin: .deviceUnsaved))
        let sinGuardar = ControlKeySource.resolve(
            rig: nil, cached: nil, stored: { .success(nil) },
            generate: { Data(repeating: 4, count: 32) }, save: { _ in false }
        )
        XCTAssertEqual(sinGuardar.origin, .deviceUnsaved)
        // Lo guardado roto (otro tamaño, no base64) se sustituye.
        var guardado: [String] = []
        let sustituida = ControlKeySource.resolve(
            rig: nil, cached: nil, stored: { .success(Data(repeating: 1, count: 8).base64EncodedString()) },
            generate: { Data(repeating: 5, count: 32) }, save: { guardado.append($0); return true }
        )
        XCTAssertEqual(sustituida.secret, Data(repeating: 5, count: 32))
        XCTAssertEqual(guardado.count, 1)
    }

    func testTheDeviceSecretIsRandomAnd32Bytes() {
        let a = ControlKeySource.randomDeviceSecret()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, ControlKeySource.randomDeviceSecret())
    }

    // MARK: - RateMeter

    func testTheRateIsTheRiseSinceTheLastReading() {
        var m = RateMeter()
        XCTAssertEqual(m.rate(count: 0, nowNs: 1_000_000_000), 0)
        XCTAssertEqual(m.rate(count: 30, nowNs: 2_000_000_000), 30, accuracy: 1e-9)
        XCTAssertEqual(m.rate(count: 45, nowNs: 2_500_000_000), 30, accuracy: 1e-9)
    }

    func testANewRunOrAStoppedClockReadsZero() {
        var m = RateMeter()
        _ = m.rate(count: 100, nowNs: 1_000)
        XCTAssertEqual(m.rate(count: 5, nowNs: 2_000), 0)
        XCTAssertEqual(m.rate(count: 10, nowNs: 2_000), 0)
    }
}
