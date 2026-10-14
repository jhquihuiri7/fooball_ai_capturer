// El QR «Soporte» del VPS (ADR 0022 §3; NUBE-16 lo emite, IOS-68 lo guarda):
//
//   {"v":1, "srt":{"host","port","path","user","pass","passphrase"},
//    "tunnel":{"url":"wss://<dominio>/tunnel/v1"}, "rig_id", "rig_key"}
//
// El Keychain guarda el texto del QR tal cual (servicio `football-ai.vps`, cuenta
// `soporte`, en el Runner) y esto lo interpreta: el publicador del programa (IOS-56) saca
// de aquí su `ProgramSrtTarget`. Es el mismo veredicto, en el mismo orden, que
// lib/src/vps_pairing.dart: los dos leen Fixtures/vps_pairing_cases.json.
//
// `rig_key` es el token del soporte (`control_token.py`). Aquí no hay secreto con el que
// verificarlo: solo se lee su rig, sus ámbitos y su caducidad. Ningún error ni
// `description` lleva un valor.

import Foundation

public enum VpsPairingFormat {
    /// La versión del JSON del QR (`PAIRING_VERSION` en tools/nube/pairing.py).
    public static let version: Int64 = 1

    /// El túnel solo con TLS: lleva el `rig_key` en la cabecera.
    public static let tunnelScheme = "wss"

    /// El ámbito que abre el túnel (`SCOPE_TUNNEL`).
    public static let tunnelScope = "tunnel"

    /// Los ámbitos que puede llevar un token (`ALL_SCOPES`): uno fuera es de otra versión.
    static let allScopes: Set<String> = ["match", "stream", "rig", "tunnel"]

    /// `FOOTBALL_VPS_DOMAIN`: `[A-Za-z0-9.-]+`.
    static let hostAlphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")

    /// `RIG_ID_PATTERN`: `[A-Za-z0-9_-]{1,64}`, porque va en rutas del VPS.
    static let rigIdAlphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    static let rigIdLength = 1...64
}

/// Por qué no vale un QR Soporte. `field` es el nombre (`srt.pass`), nunca el valor.
public enum VpsPairingError: Error, Equatable, CustomStringConvertible {
    case notSupport
    case version
    case field(String)
    case expired

    public var description: String {
        switch self {
        case .notSupport: return "no es un QR Soporte"
        case .version: return "QR Soporte de otra versión"
        case let .field(nombre): return "el QR Soporte no trae bien «\(nombre)»"
        case .expired: return "el rig_key del QR Soporte caducó"
        }
    }
}

public struct VpsPairing: Equatable, Sendable, CustomStringConvertible {
    public let srt: ProgramSrtTarget
    public let tunnelUrl: URL
    public let rigId: String
    /// El Bearer del túnel y de las rutas HTTP de los móviles.
    public let rigKey: String
    /// Cuándo caduca `rigKey`, en segundos de hora de pared.
    public let rigKeyExpiresS: Int64

    /// Con quién está emparejado: el host del túnel.
    public var domain: String { tunnelUrl.host?.lowercased() ?? "" }

    public func isExpired(nowS: Int64) -> Bool { rigKeyExpiresS <= nowS }

    /// Para los logs: sin clave, passphrase ni `rig_key`.
    public var description: String { "VpsPairing(\(domain), rig \(rigId), caduca \(rigKeyExpiresS))" }

    /// Lee y valida el QR. Con `nowS`, además rechaza un `rig_key` caducado (al escanear);
    /// sin él, no (al leer del Keychain: el SRT sigue valiendo aunque caduque el túnel).
    public static func parse(_ text: String, nowS: Int64? = nil) throws -> VpsPairing {
        let qr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .object(raiz)? = try? JSONDecoder().decode(PairingJson.self, from: Data(qr.utf8)),
              let v = raiz["v"]
        else { throw VpsPairingError.notSupport }
        guard case .int(VpsPairingFormat.version) = v else { throw VpsPairingError.version }

        let s = try object(raiz, "srt", "srt")
        let host = try string(s, "host", "srt.host", VpsPairingFormat.hostAlphabet)
        guard case let .int(puerto)? = s["port"], let port = UInt16(exactly: puerto), port >= 1 else {
            throw VpsPairingError.field("srt.port")
        }
        let path = try string(s, "path", "srt.path", ProgramSrtStreamId.freeAlphabet)
        let user = try string(s, "user", "srt.user", ProgramSrt.credentialAlphabet)
        let pass = try string(s, "pass", "srt.pass", ProgramSrt.credentialAlphabet)
        let passphrase = try string(s, "passphrase", "srt.passphrase", nil)
        let srt = ProgramSrtTarget(host: host, port: port, path: path, user: user, pass: pass,
                                   passphrase: passphrase)
        guard (try? srt.streamId()) != nil else { throw VpsPairingError.field("srt") }
        guard (try? srt.checkedPassphrase()) != nil else { throw VpsPairingError.field("srt.passphrase") }

        let t = try object(raiz, "tunnel", "tunnel")
        let url = try string(t, "url", "tunnel.url", nil)
        guard let partes = URLComponents(string: url), partes.scheme?.lowercased() == VpsPairingFormat.tunnelScheme,
              !(partes.host ?? "").isEmpty, partes.user == nil, partes.password == nil, let tunnelUrl = partes.url
        else { throw VpsPairingError.field("tunnel.url") }

        let rigId = try string(raiz, "rig_id", "rig_id", VpsPairingFormat.rigIdAlphabet)
        guard VpsPairingFormat.rigIdLength.contains(rigId.count) else { throw VpsPairingError.field("rig_id") }
        let rigKey = try string(raiz, "rig_key", "rig_key", nil)
        guard let claims = SupportTokenClaims.peek(rigKey), claims.rigId == rigId,
              claims.scopes.contains(VpsPairingFormat.tunnelScope)
        else { throw VpsPairingError.field("rig_key") }
        if let nowS, claims.expiresS <= nowS { throw VpsPairingError.expired }
        return VpsPairing(srt: srt, tunnelUrl: tunnelUrl, rigId: rigId, rigKey: rigKey,
                          rigKeyExpiresS: claims.expiresS)
    }

    private static func object(_ m: [String: PairingJson], _ key: String, _ field: String) throws -> [String: PairingJson] {
        guard case let .object(valor)? = m[key] else { throw VpsPairingError.field(field) }
        return valor
    }

    /// Un texto no vacío del alfabeto, si lo hay. La passphrase y la URL se miran aparte.
    private static func string(_ m: [String: PairingJson], _ key: String, _ field: String,
                               _ alphabet: Set<Character>?) throws -> String {
        guard case let .string(valor)? = m[key] else { throw VpsPairingError.field(field) }
        if let alphabet, valor.isEmpty || !valor.allSatisfy(alphabet.contains) {
            throw VpsPairingError.field(field)
        }
        return valor
    }
}

/// Lo que dice un token del soporte **sin comprobar la firma** (`peek_claims`): para decir
/// a tiempo «escanea otra vez». Nunca abre nada.
struct SupportTokenClaims: Equatable {
    let rigId: String?
    let scopes: Set<String>
    let expiresS: Int64

    /// `base64url(json).base64url(hmac)` sin relleno. `nil` si no se lee o es de otra versión.
    static func peek(_ token: String) -> SupportTokenClaims? {
        let partes = token.split(separator: ".", omittingEmptySubsequences: false)
        let base64url = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard partes.count == 2, partes.allSatisfy({ !$0.isEmpty && $0.allSatisfy(base64url.contains) }) else {
            return nil
        }
        var b64 = partes[0].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let datos = Data(base64Encoded: b64),
              case let .object(c)? = try? JSONDecoder().decode(PairingJson.self, from: datos),
              case let .array(ambitos)? = c["s"], case let .int(caduca)? = c["e"]
        else { return nil }
        let nombres = ambitos.compactMap { (j: PairingJson) -> String? in
            if case let .string(a) = j { return a }
            return nil
        }
        var rig: String?
        switch c["r"] {
        case nil, .null?: rig = nil
        case let .string(r)?: rig = r
        default: return nil
        }
        switch c["g"] {
        case nil, .null?: break
        case let .int(g)? where g >= 0: break
        default: return nil
        }
        switch c["m"] {
        case nil, .null?: guard rig != nil else { return nil }  // ni de un partido ni de un rig
        case .string?: break
        default: return nil
        }
        guard nombres.count == ambitos.count, Set(nombres).isSubset(of: VpsPairingFormat.allScopes) else { return nil }
        if let rig, !(VpsPairingFormat.rigIdLength.contains(rig.count) && rig.allSatisfy(VpsPairingFormat.rigIdAlphabet.contains)) {
            return nil
        }
        return SupportTokenClaims(rigId: rig, scopes: Set(nombres), expiresS: caduca)
    }
}

/// Un JSON cualquiera, sin perder la diferencia entre `true`, `1` y `1.5` que borra
/// JSONSerialization (todo es NSNumber).
enum PairingJson: Decodable, Equatable {
    case object([String: PairingJson])
    case array([PairingJson])
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([PairingJson].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: PairingJson].self))
        }
    }
}
