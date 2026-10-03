import XCTest

@testable import RigMedia

/// Lo que de SPK-03 se puede probar sin cámara: los parámetros del banco y los
/// bitrates por perfil. El informe de verdad sale de los dos iPhone.
final class VtConcurrencyBenchTests: XCTestCase {
    func testTheDefaultsAreTheCardValues() {
        let config = VtConcurrencyBench.config(from: [:])
        XCTAssertEqual(config.profile, .master)
        XCTAssertEqual(config.durationS, 1800)
        XCTAssertTrue(config.hevc)
        XCTAssertEqual(config.h264BitrateBps, 6_000_000)
        XCTAssertEqual(VtConcurrencyBench.hevcBitrateBps, 45_000_000)
    }

    func testHevcCanBeTurnedOffForTheRetryTheCardPrescribes() {
        XCTAssertFalse(VtConcurrencyBench.config(from: ["hevc": "0"]).hevc)
        XCTAssertTrue(VtConcurrencyBench.config(from: ["hevc": "1"]).hevc)
    }

    func testTheSlaveProfileRaisesTheBitrate() {
        let config = VtConcurrencyBench.config(
            from: ["profile": "slave", "duration_s": "30"]
        )
        XCTAssertEqual(config.profile, .slave)
        XCTAssertEqual(config.durationS, 30)
        XCTAssertEqual(config.h264BitrateBps, 25_000_000)
    }

    func testGarbageParamsFallBackToDefaults() {
        let config = VtConcurrencyBench.config(
            from: ["profile": "jefe", "duration_s": "mucho"]
        )
        XCTAssertEqual(config.profile, .master)
        XCTAssertEqual(config.durationS, 1800)
    }
}
