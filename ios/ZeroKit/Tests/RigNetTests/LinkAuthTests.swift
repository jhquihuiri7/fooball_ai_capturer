import Foundation
import XCTest

import RigCore
@testable import RigNet

/// La seguridad del enlace (IOS-16): lo que abre con el secreto bueno y cierra con
/// cualquier otro. Sin vectores externos: las dos mitades son esta misma biblioteca,
/// y lo que se fija es el comportamiento del protocolo.
final class LinkAuthTests: XCTestCase {
    private let secretoA = Data(repeating: 0x11, count: 32)
    private let secretoB = Data(repeating: 0x22, count: 32)
    private let helloIzq = Data("hello-izquierda".utf8)
    private let helloDer = Data("hello-derecha".utf8)

    func testTheRightSecretOpensAndTheWrongOneCloses() {
        let mac = LinkAuth.authMac(secret: secretoA, myHello: helloDer, theirHello: helloIzq)

        XCTAssertTrue(LinkAuth.verifyAuth(secret: secretoA, mac: mac, theirHello: helloDer, myHello: helloIzq))
        XCTAssertFalse(LinkAuth.verifyAuth(secret: secretoB, mac: mac, theirHello: helloDer, myHello: helloIzq))
        // Cambiar cualquiera de los dos hello también lo tira.
        XCTAssertFalse(LinkAuth.verifyAuth(secret: secretoA, mac: mac, theirHello: helloIzq, myHello: helloIzq))
    }

    func testFingerprintIsStableShortAndSecretDependent() {
        let huella = LinkAuth.fingerprint(secret: secretoA)
        XCTAssertEqual(huella.count, 8)
        XCTAssertEqual(huella, LinkAuth.fingerprint(secret: secretoA))
        XCTAssertNotEqual(huella, LinkAuth.fingerprint(secret: secretoB))
    }

    func testBothSidesDeriveTheSameSessionAndId() {
        let nonceIzq = Data((0..<16).map { UInt8($0) })
        let nonceDer = Data((0..<16).map { UInt8(100 + $0) })

        let kIzq = LinkAuth.sessionKey(secret: secretoA, nonceLeft: nonceIzq, nonceRight: nonceDer)
        let kDer = LinkAuth.sessionKey(secret: secretoA, nonceLeft: nonceIzq, nonceRight: nonceDer)

        XCTAssertEqual(LinkAuth.sessionId(key: kIzq), LinkAuth.sessionId(key: kDer))
        XCTAssertNotEqual(LinkAuth.sessionId(key: kIzq), 0)
        // Con otros nonces, otra sesión: reconectar nunca reutiliza la vieja.
        let otra = LinkAuth.sessionKey(secret: secretoA, nonceLeft: nonceDer, nonceRight: nonceIzq)
        XCTAssertNotEqual(LinkAuth.sessionId(key: kIzq), LinkAuth.sessionId(key: otra))
    }

    func testFrameTagsVerifyAndTamperingIsCaught() {
        let key = LinkAuth.sessionKey(
            secret: secretoA,
            nonceLeft: Data(repeating: 1, count: 16),
            nonceRight: Data(repeating: 2, count: 16)
        )
        var frame = LinkFrame(
            type: .detections, session: 7, seq: 3, rigMs: 99,
            payload: Data([1, 2, 3]), tag: Data()
        )
        frame.tag = LinkAuth.tag(key: key, frame: frame)

        XCTAssertEqual(frame.tag.count, LinkFrame.tagLength)
        XCTAssertTrue(LinkAuth.verifyTag(key: key, frame: frame))

        var tocada = frame
        tocada.payload = Data([1, 2, 4])
        XCTAssertFalse(LinkAuth.verifyTag(key: key, frame: tocada))
    }

    func testTheControlSecretIsDerivedPerMatch() {
        let token = LinkAuth.controlSecret(secret: secretoA, matchId: "m_20261003_1422_d97c")

        XCTAssertEqual(token.count, 43)  // por encima del mínimo de 32 del ADR 0017
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
        // Otro partido u otro secreto revocan todos los tokens.
        XCTAssertNotEqual(token, LinkAuth.controlSecret(secret: secretoA, matchId: "m_otro"))
        XCTAssertNotEqual(token, LinkAuth.controlSecret(secret: secretoB, matchId: "m_20261003_1422_d97c"))
    }
}
