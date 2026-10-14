import Foundation
@testable import RigCore
import XCTest

/// El QR Soporte del VPS (ADR 0022 §3; IOS-68). Los casos los comparte con
/// test/vps_pairing_test.dart: Swift y Dart tienen que dar el mismo veredicto.
final class VpsPairingTests: XCTestCase {
    private struct Casos: Decodable {
        let now_s: Int64
        let cases: [Caso]
    }

    private struct Caso: Decodable {
        let name: String
        let qr: String
        let now_s: Int64?
        let expected: Esperado
    }

    private struct Esperado: Decodable {
        let ok: Bueno?
        let error: String?
        let field: String?
    }

    private struct Bueno: Decodable {
        let host: String
        let port: UInt16
        let path: String
        let user: String
        let pass: String
        let passphrase: String
        let tunnel_url: String
        let domain: String
        let rig_id: String
        let rig_key: String
        let expires_s: Int64
    }

    private func casos() throws -> Casos {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vps_pairing_cases", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Casos.self, from: Data(contentsOf: url))
    }

    func testLosCasosCompartidos() throws {
        let doc = try casos()
        XCTAssertGreaterThan(doc.cases.count, 30)
        for caso in doc.cases {
            let ahora = caso.now_s ?? doc.now_s
            if let bueno = caso.expected.ok {
                let p = try VpsPairing.parse(caso.qr, nowS: ahora)
                XCTAssertEqual(p.srt, ProgramSrtTarget(host: bueno.host, port: bueno.port, path: bueno.path,
                                                       user: bueno.user, pass: bueno.pass,
                                                       passphrase: bueno.passphrase), caso.name)
                XCTAssertEqual(p.tunnelUrl.absoluteString, bueno.tunnel_url, caso.name)
                XCTAssertEqual(p.domain, bueno.domain, caso.name)
                XCTAssertEqual(p.rigId, bueno.rig_id, caso.name)
                XCTAssertEqual(p.rigKey, bueno.rig_key, caso.name)
                XCTAssertEqual(p.rigKeyExpiresS, bueno.expires_s, caso.name)
            } else {
                let esperado: VpsPairingError = switch caso.expected.error {
                case "not_support": .notSupport
                case "version": .version
                case "expired": .expired
                default: .field(caso.expected.field ?? "?")
                }
                XCTAssertThrowsError(try VpsPairing.parse(caso.qr, nowS: ahora), caso.name) {
                    XCTAssertEqual($0 as? VpsPairingError, esperado, caso.name)
                }
            }
        }
    }

    func testDelKeychainNoMiraLaCaducidad() throws {
        // El Keychain guarda el QR aunque el rig_key caduque: el SRT sigue valiendo, y el
        // túnel dirá «escanea otra vez» con el 4401.
        let qr = try XCTUnwrap(casos().cases.first { $0.name == "del_vps" }).qr
        let p = try VpsPairing.parse(qr)
        XCTAssertEqual(p.rigKeyExpiresS, 1_800_043_200)
        XCTAssertTrue(p.isExpired(nowS: 1_800_043_200))
        XCTAssertFalse(p.isExpired(nowS: 1_800_043_199))
        XCTAssertEqual(try p.srt.streamId(), "publish:programa:maestro:clave-del-programa.1")
        XCTAssertEqual(try p.srt.checkedPassphrase(), "frase-del-srt-2026")
    }

    func testNingunSecretoEnLosTextos() throws {
        let doc = try casos()
        let qr = try XCTUnwrap(doc.cases.first { $0.name == "del_vps" }).qr
        let p = try VpsPairing.parse(qr, nowS: doc.now_s)
        let secretos = [p.srt.pass, p.srt.passphrase, p.rigKey, String(p.rigKey.split(separator: ".")[1])]
        var textos = ["\(p)", String(reflecting: p), "\(p.srt)"]
        for caso in doc.cases where caso.expected.ok == nil {
            do { _ = try VpsPairing.parse(caso.qr, nowS: caso.now_s ?? doc.now_s) } catch {
                textos += ["\(error)", String(reflecting: error), error.localizedDescription]
            }
        }
        for texto in textos {
            for secreto in secretos {
                XCTAssertFalse(texto.contains(secreto), texto)
            }
        }
        XCTAssertEqual("\(p)", "VpsPairing(vps.ejemplo.com, rig rig-01, caduca 1800043200)")
    }

    func testElTokenSinFirmaSeLeeComoEnPython() {
        // peek_claims: lo que dice el token, sin comprobar la firma.
        let delSoporte = "eyJyIjoicmlnLTAxIiwicyI6WyJ0dW5uZWwiXSwiZSI6MTgwMDA0MzIwMCwiZyI6MH0.yJK-Mu84D5tgRWGpJPjdxJJjUzn_TV1RLZFhYcvu-7U"
        XCTAssertEqual(SupportTokenClaims.peek(delSoporte),
                       SupportTokenClaims(rigId: "rig-01", scopes: ["tunnel"], expiresS: 1_800_043_200))
        for malo in ["", "sin-punto", "a.b.c", ".firma", "eyJ9.firma", "e30.firma",  // {} no es de nadie
                     "eyJyIjoicmlnIiwicyI6WyJlc3Blam8iXSwiZSI6MX0.f",  // ámbito «espejo»
                     "eyJyIjoicmlnIiwicyI6W10sImUiOnRydWV9.f"] {  // e: true no es un entero
            XCTAssertNil(SupportTokenClaims.peek(malo), malo)
        }
    }
}
