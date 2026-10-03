import Foundation
import XCTest

@testable import RigCore

/// La SEI del tiempo del soporte (IOS-50, ADR 0022): ida y vuelta, la prevención de
/// emulación —que un rigMs pequeño pisa SIEMPRE— y el recorrido por AVCC.
final class H264SeiTests: XCTestCase {
    func testRoundTripKeepsRigMsAndViewId() {
        let nal = H264Sei.build(rigMs: 1_234_567_890_123, viewId: 7)
        let parsed = H264Sei.parse(nal: nal)
        XCTAssertEqual(parsed?.rigMs, 1_234_567_890_123)
        XCTAssertEqual(parsed?.viewId, 7)
    }

    /// Un rigMs pequeño empieza por seis ceros: sin escape, la NAL llevaría un
    /// arranque falso (00 00 00/01) y un decodificador la partiría por ahí.
    func testASmallRigMsForcesEmulationPreventionAndStillRoundTrips() {
        let nal = H264Sei.build(rigMs: 1, viewId: 0)
        // Ningún 00 00 00/01/02 puede quedar en la NAL ya escapada.
        let bytes = [UInt8](nal)
        for i in 0..<(bytes.count - 2) {
            let ventana = (bytes[i], bytes[i + 1], bytes[i + 2])
            XCTAssertFalse(
                ventana.0 == 0 && ventana.1 == 0 && ventana.2 <= 0x02,
                "arranque falso en \(i)"
            )
        }
        let parsed = H264Sei.parse(nal: nal)
        XCTAssertEqual(parsed?.rigMs, 1)
        XCTAssertEqual(parsed?.viewId, 0)
    }

    func testEveryRigMsShapeRoundTrips() {
        let valores: [UInt64] = [0, 1, 255, 256, 0x0003_0000, 0x0000_0300_0000_0000, .max]
        for rigMs in valores {
            for viewId: UInt8 in [0, 1, 3] {
                let parsed = H264Sei.parse(nal: H264Sei.build(rigMs: rigMs, viewId: viewId))
                XCTAssertEqual(parsed?.rigMs, rigMs, "\(rigMs)")
                XCTAssertEqual(parsed?.viewId, viewId, "\(rigMs)")
            }
        }
    }

    func testForeignNalsAreNotOurs() {
        // Otro tipo de NAL (slice IDR, tipo 5).
        XCTAssertNil(H264Sei.parse(nal: Data([0x65, 0x01, 0x02, 0x03])))
        // SEI de otro payload (buffering_period, tipo 0).
        XCTAssertNil(H264Sei.parse(nal: Data([0x06, 0x00, 0x01, 0xFF, 0x80])))
        // SEI user_data_unregistered de otro UUID.
        var ajena = Data([0x06, 0x05, 25])
        ajena.append(Data(repeating: 0xAB, count: 16))
        ajena.append(Data(repeating: 0x01, count: 9))
        ajena.append(0x80)
        XCTAssertNil(H264Sei.parse(nal: ajena))
        XCTAssertNil(H264Sei.parse(nal: Data()))
    }

    func testInsertPutsTheSeiInsideTheAccessUnitAndFindGetsItBack() {
        // Una muestra AVCC con dos NAL cualesquiera (longitud 4B + bytes).
        var sample = Data()
        sample.appendBigEndian(UInt32(3))
        sample.append(Data([0x65, 0xAA, 0xBB]))
        sample.appendBigEndian(UInt32(2))
        sample.append(Data([0x41, 0xCC]))

        let out = H264Sei.insert(intoAvcc: sample, rigMs: 55_555, viewId: 1)
        // La SEI va delante y la muestra queda intacta detrás.
        XCTAssertTrue(out.suffix(sample.count) == sample)
        let found = H264Sei.find(inAvcc: out)
        XCTAssertEqual(found?.rigMs, 55_555)
        XCTAssertEqual(found?.viewId, 1)
        // La muestra sin SEI no encuentra nada, y una truncada tampoco revienta.
        XCTAssertNil(H264Sei.find(inAvcc: sample))
        XCTAssertNil(H264Sei.find(inAvcc: out.prefix(6)))
    }

    func testEscapeAndUnescapeAreExactInverses() {
        let crudos: [Data] = [
            Data(),
            Data([0x00, 0x00, 0x00]),
            Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x02]),
            Data([0x00, 0x00, 0x03, 0x00, 0x00, 0x03]),  // un 03 de verdad se conserva
            Data((0...255).map { UInt8($0) }),
        ]
        for rbsp in crudos {
            let escapado = H264Sei.escape(rbsp)
            XCTAssertEqual(H264Sei.unescape(escapado), rbsp, "\([UInt8](rbsp))")
        }
    }
}
