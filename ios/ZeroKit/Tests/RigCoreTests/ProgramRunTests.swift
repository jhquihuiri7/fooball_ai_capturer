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
    }

    // MARK: - LinkChoice

    func testWithoutEnvironmentTheScreenDecides() {
        XCTAssertEqual(LinkChoice.resolve(environment: [:], requested: .network(.aware)), .network(.aware))
        XCTAssertEqual(LinkChoice.resolve(environment: [:], requested: .multipeer), .multipeer)
        // RIG_LINK_INTERFACE sola no cambia nada: hace falta RIG_LINK_MULTIPEER=0, como antes.
        XCTAssertEqual(LinkChoice.resolve(environment: ["RIG_LINK_INTERFACE": "wifi"], requested: .multipeer),
                       .multipeer)
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
