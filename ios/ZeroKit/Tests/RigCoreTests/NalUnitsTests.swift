import Foundation
import XCTest

import RigCore

/// El paso AVCC ↔ Annex B (IOS-51): ida y vuelta, códigos de arranque de 3 y 4
/// bytes, y que una muestra corrupta no mande a leer fuera.
final class NalUnitsTests: XCTestCase {
    private func avcc(_ nals: [[UInt8]]) -> Data {
        var out = Data()
        for nal in nals {
            out.appendBigEndian(UInt32(nal.count))
            out.append(Data(nal))
        }
        return out
    }

    func testAvccToAnnexBAndBackIsTheIdentity() {
        let sample = avcc([[0x67, 0x42], [0x68, 0xCE], [0x65, 0x11, 0x22, 0x33]])
        let annexB = NalUnits.annexB(fromAvcc: sample)
        // Tres códigos de arranque largos, uno por NAL.
        XCTAssertEqual(annexB.prefix(4), Data([0, 0, 0, 1]))
        XCTAssertEqual(NalUnits.avcc(fromAnnexB: annexB), sample)
    }

    func testShortStartCodesAlsoParse() {
        // ffmpeg y los .ts mezclan códigos de 3 y de 4 bytes.
        var stream = Data([0x00, 0x00, 0x01, 0x67, 0x42])
        stream.append(Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x99]))
        let sample = NalUnits.avcc(fromAnnexB: stream)
        XCTAssertEqual(sample, avcc([[0x67, 0x42], [0x65, 0x99]]))
    }

    func testTypesReadsTheNalCatalog() {
        let sample = avcc([[0x67, 0x42], [0x68, 0xCE], [0x06, 0x05], [0x65, 0x11]])
        XCTAssertEqual(NalUnits.types(inAvcc: sample), [7, 8, 6, 5])
    }

    func testACorruptLengthStopsInsteadOfReadingBeyond() {
        var corrupta = avcc([[0x67, 0x42]])
        corrupta.appendBigEndian(UInt32(1000))  // longitud que apunta fuera
        corrupta.append(Data([0x65]))
        XCTAssertEqual(NalUnits.types(inAvcc: corrupta), [7])
        // Y un Annex B sin ningún código de arranque no inventa NALs.
        XCTAssertEqual(NalUnits.avcc(fromAnnexB: Data([0x11, 0x22, 0x33])), Data())
    }
}
