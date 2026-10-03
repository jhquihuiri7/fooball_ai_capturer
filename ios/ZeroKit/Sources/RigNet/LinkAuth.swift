// La seguridad del enlace (IOS-16, ADR 0023 §3): huella, auth mutuo, clave de sesión
// y el tag de cada trama.
//
// `S` es el secreto del soporte: 32 B que viven en el Keychain de los dos móviles
// (los aprovisiona IOS-97; en el banco, un secreto de prueba). Nada secreto viaja en
// claro: el auth es un HMAC sobre los dos `hello` tal como viajaron, la clave de
// sesión sale por HKDF de los dos nonces, y el secreto del mando se DERIVA en cada
// móvil, nunca se transmite.
//
// Vive en RigNet y no en RigCore a propósito: RigCore solo importa Foundation
// (check_layers), y esto necesita CryptoKit.

import CryptoKit
import Foundation
import RigCore

public enum LinkAuth {
    static let idInfo = Data("zero-link-v1 id".utf8)
    static let authInfo = Data("zero-link-v1 auth".utf8)
    static let sessionInfo = Data("zero-link-v1 sesión".utf8)
    static let sealInfo = Data("zero-link-v1 sello".utf8)
    static let controlPrefix = "zero-control-v1 "

    /// La huella que va en la TXT: 8 hex de HMAC(S, "zero-link-v1 id"), para no
    /// intentar emparejar con el móvil de otro soporte.
    public static func fingerprint(secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: idInfo, using: SymmetricKey(data: secret))
        return Data(mac).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// El `mac` del mensaje `auth`: HMAC(S, "…auth" ‖ mi hello ‖ el hello del otro),
    /// sobre los bytes tal como viajaron.
    public static func authMac(secret: Data, myHello: Data, theirHello: Data) -> Data {
        var mensaje = authInfo
        mensaje.append(myHello)
        mensaje.append(theirHello)
        return Data(HMAC<SHA256>.authenticationCode(for: mensaje, using: SymmetricKey(data: secret)))
    }

    /// Verifica el `auth` del otro (sus bytes son su hello ‖ el mío, en SU orden).
    /// Comparación en tiempo constante: un `mac` es un secreto aunque sea ajeno.
    public static func verifyAuth(
        secret: Data, mac: Data, theirHello: Data, myHello: Data
    ) -> Bool {
        constantTimeEquals(
            authMac(secret: secret, myHello: theirHello, theirHello: myHello),
            mac
        )
    }

    /// K = HKDF-SHA256(S, salt = nonce_izq ‖ nonce_der, info = "…sesión").
    public static func sessionKey(secret: Data, nonceLeft: Data, nonceRight: Data) -> SymmetricKey {
        var salt = nonceLeft
        salt.append(nonceRight)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: sessionInfo,
            outputByteCount: 32
        )
    }

    /// `session`: los 4 primeros bytes de HMAC(K, "id"), big-endian.
    public static func sessionId(key: SymmetricKey) -> UInt32 {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("id".utf8), using: key))
        return mac.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// El `tag` de una trama: los 16 primeros bytes de HMAC(K, cabecera ‖ payload).
    /// Por UDP se firma la trama reensamblada, no cada fragmento.
    public static func tag(key: SymmetricKey, frame: LinkFrame) -> Data {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: frame.signableBytes(), using: key))
        return mac.prefix(LinkFrame.tagLength)
    }

    public static func verifyTag(key: SymmetricKey, frame: LinkFrame) -> Bool {
        constantTimeEquals(tag(key: key, frame: frame), frame.tag)
    }

    /// El secreto del mando, derivado por partido: HMAC(S, "zero-control-v1 " ‖
    /// match_id) en base64url (43 caracteres). Lo calculan los dos móviles; rotarlo es
    /// cambiar `match_id` o `S`.
    public static func controlSecret(secret: Data, matchId: String) -> String {
        let mensaje = Data((controlPrefix + matchId).utf8)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: mensaje, using: SymmetricKey(data: secret)))
        return mac.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
