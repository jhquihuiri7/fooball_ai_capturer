import XCTest

@testable import RigCore

final class FragmenterTests: XCTestCase {
    private func frame(bytes: Int, seed: UInt8 = 1) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0) })
    }

    func testASmallFrameTravelsInOneDatagram() {
        let original = frame(bytes: 100)
        let datagramas = Fragmenter.fragment(frame: original, session: 1, seq: 0)

        XCTAssertEqual(datagramas.count, 1)
        let reensamblador = Reassembler()
        XCTAssertEqual(reensamblador.push(datagramas[0]), original)
    }

    func testOutOfOrderFragmentsReassemble() {
        let original = frame(bytes: LinkConstants.datagramPayloadB * 3 + 17)
        var datagramas = Fragmenter.fragment(frame: original, session: 1, seq: 9)
        XCTAssertEqual(datagramas.count, 4)
        datagramas.shuffle()

        let reensamblador = Reassembler()
        var completas: [Data] = []
        for datagrama in datagramas {
            if let trama = reensamblador.push(datagrama) {
                completas.append(trama)
            }
        }
        XCTAssertEqual(completas, [original])
        XCTAssertEqual(reensamblador.incompleteFrames, 0)
    }

    func testALostFragmentDropsTheFrameAndCounts() {
        let reensamblador = Reassembler(maxPartials: 2)
        // Cuatro tramas a medias (falta un fragmento de cada): con hueco para 2, las
        // dos primeras acaban expulsadas y contadas.
        for seq in 0..<4 {
            let datagramas = Fragmenter.fragment(
                frame: frame(bytes: LinkConstants.datagramPayloadB * 2, seed: UInt8(seq)),
                session: 1,
                seq: UInt32(seq)
            )
            XCTAssertNil(reensamblador.push(datagramas[0]))
        }
        XCTAssertEqual(reensamblador.incompleteFrames, 2)
    }

    func testDuplicatesAndGarbageAreCountedNotCrashed() {
        let original = frame(bytes: LinkConstants.datagramPayloadB + 5)
        let datagramas = Fragmenter.fragment(frame: original, session: 1, seq: 3)
        let reensamblador = Reassembler()

        XCTAssertNil(reensamblador.push(datagramas[0]))
        XCTAssertNil(reensamblador.push(datagramas[0]))  // duplicado: se ignora
        XCTAssertEqual(reensamblador.push(datagramas[1]), original)

        XCTAssertNil(reensamblador.push(Data([1, 2, 3])))
        XCTAssertEqual(reensamblador.invalidDatagrams, 1)
    }

    func testEveryDatagramFitsTheIPv6Mtu() {
        let original = frame(bytes: 100_000)
        for datagrama in Fragmenter.fragment(frame: original, session: 1, seq: 0) {
            XCTAssertLessThanOrEqual(
                datagrama.count,
                Fragmenter.datagramHeaderLength + LinkConstants.datagramPayloadB
            )
        }
    }
}
