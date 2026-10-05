import Foundation
import XCTest

@testable import RigCore

/// La parte y la vista en el cable (IOS-52): ida y vuelta, f32 y basura.
final class PartPacketTests: XCTestCase {
    private func vista(id: UInt32 = 7, sides: [CameraSide] = [.left, .right]) -> ViewCommand {
        ViewCommand(
            targetRigMs: 123_456_789, viewId: id, yawRad: 0.1234567, pitchRad: -0.05,
            hfovRad: 1.2, sides: sides, seamYawRad: 0.01, featherRad: 0.02,
            gains: ColorGains(left: [1.01, 0.99, 1.0], right: [0.98, 1.02, 1.03])
        )
    }

    func testLaParteVaYVuelveConSusFlags() throws {
        let au = Data((0..<5000).map { UInt8($0 & 0xFF) })
        let parte = PartPacket(
            partSeq: 42, frameRigMs: 987_654, view: ViewWire.quantized(vista()),
            extrapolated: true, isKey: true, accessUnit: au
        )
        var trama = parte.frame(session: 9, seq: 3)
        trama.tag = Data(count: LinkFrame.tagLength)  // lo pone la sesión al sellar
        XCTAssertEqual(trama.flags, [.idr, .extrapolated])
        XCTAssertEqual(trama.rigMs, 987_654)
        guard case let .frame(cruda, _) = LinkFrame.decode(from: trama.encode()) else {
            return XCTFail("la trama no se lee")
        }
        let leida = try XCTUnwrap(PartPacket.decode(cruda))
        XCTAssertEqual(leida, parte)
    }

    func testLaVistaViajaEnF32YCuantizarEsIdempotente() throws {
        let q = ViewWire.quantized(vista())
        XCTAssertEqual(q.yawRad, Double(Float(0.1234567)))
        XCTAssertNotEqual(q.yawRad, 0.1234567)
        XCTAssertEqual(ViewWire.quantized(q), q)
        XCTAssertEqual(q.sides, [.left, .right])
        XCTAssertEqual(q.gains.right, [0.98, 1.02, 1.03].map { Double(Float($0)) })
        XCTAssertEqual(ViewWire.quantized(vista(sides: [.right])).sides, [.right])
        XCTAssertEqual(ViewWire.quantized(vista(sides: [])).sides, [])
    }

    func testElHistorialDeVistas() throws {
        let vistas = (1...3).map { ViewWire.quantized(vista(id: UInt32($0))) }
        let payload = ViewWire.encodeHistory(vistas)
        XCTAssertEqual(payload.count, 1 + 3 * ViewWire.encodedLength)
        XCTAssertEqual(ViewWire.decodeHistory(payload), vistas)
        XCTAssertNil(ViewWire.decodeHistory(payload.dropLast()))
        XCTAssertNil(ViewWire.decodeHistory(payload + Data([0])), "bytes de sobra: basura")
    }

    func testBasuraNoEsUnaParte() {
        var corta = PartPacket(
            partSeq: 1, frameRigMs: 1, view: vista(), extrapolated: false, isKey: false,
            accessUnit: Data([1])
        ).frame()
        corta.payload = corta.payload.prefix(10)
        XCTAssertNil(PartPacket.decode(corta))
        var sinAU = corta
        sinAU.payload = Data(count: 4 + ViewWire.encodedLength)
        XCTAssertNil(PartPacket.decode(sinAU), "una parte sin unidad de acceso no es nada")
        var lados = PartPacket(
            partSeq: 1, frameRigMs: 1, view: vista(), extrapolated: false, isKey: false,
            accessUnit: Data([1])
        ).frame()
        lados.payload[4 + 8 + 4 + 20] = 0b100
        XCTAssertNil(PartPacket.decode(lados), "un lado que no existe")
    }

    func testNoPartEIdrRequest() throws {
        let np = NoPartPacket(frameRigMs: 5000, viewId: 77)
        XCTAssertEqual(NoPartPacket.decode(np.frame()), np)
        XCTAssertEqual(IdrRequestWire.decode(IdrRequestWire.encode(partSeq: 0xDEAD_BEEF)), 0xDEAD_BEEF)
        XCTAssertNil(IdrRequestWire.decode(Data([1, 2])))
    }
}
