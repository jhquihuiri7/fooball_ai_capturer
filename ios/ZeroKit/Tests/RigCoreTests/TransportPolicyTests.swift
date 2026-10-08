import XCTest

@testable import RigCore

/// El medio del enlace que elige RIG_LINK_INTERFACE (IOS-14). La política automática y
/// el cambio en caliente son de IOS-17.
final class TransportPolicyTests: XCTestCase {
    func testWithoutSettingTheLinkGoesByCable() {
        XCTAssertEqual(LinkMedium.parse(nil), .ethernet)
        XCTAssertEqual(LinkMedium.parse(""), .ethernet)
        XCTAssertEqual(LinkMedium.parse("  "), .ethernet)
    }

    func testEveryMediumParsesByItsName() {
        for medio in LinkMedium.allCases {
            XCTAssertEqual(LinkMedium.parse(medio.rawValue), medio)
            XCTAssertEqual(LinkMedium.parse(medio.rawValue.uppercased()), medio)
        }
        XCTAssertEqual(LinkMedium.parse("wifi-aware"), .aware)
        XCTAssertEqual(LinkMedium.parse(" aware "), .aware)
    }

    func testAnUnknownSettingIsNotSilentlyTheCable() {
        // Una errata en el banco no puede acabar midiendo Ethernet sin saberlo.
        XCTAssertNil(LinkMedium.parse("awre"))
        XCTAssertNil(LinkMedium.parse("wlan"))
    }

    func testPartBitratePerMedium() {
        XCTAssertEqual(LinkMedium.ethernet.partBitrateBps, LinkConstants.partBitrateEthernetBps)
        XCTAssertEqual(LinkMedium.wifi.partBitrateBps, LinkConstants.partBitrateWifiBps)
        // Hasta SPK-08, Wi-Fi Aware no pasa de lo medido por la Wi-Fi del router.
        XCTAssertLessThanOrEqual(LinkMedium.aware.partBitrateBps, LinkConstants.partBitrateWifiBps)
        XCTAssertGreaterThan(LinkMedium.aware.partBitrateBps, 0)
    }

    func testOnlyWiFiAwareNeedsPairing() {
        XCTAssertEqual(LinkMedium.allCases.filter(\.needsPairing), [.aware])
    }
}
