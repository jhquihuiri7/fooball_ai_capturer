// El programa por SRT hacia el VPS (ADR 0022 §1-§3; IOS-55, IOS-56): las constantes del
// contrato, el destino que trae el QR Soporte y el streamid que se le manda a MediaMTX.
//
// MediaMTX lee `publish:<ruta>[:<usuario>:<clave>][:<query>]`, de 2 a 5 partes, y si no lo
// entiende lo escribe ENTERO en su log de info, con la clave. Por eso se comprueba aquí,
// antes de enviarlo: 512 caracteres como mucho y ningún «:» dentro de un valor. Usuario y
// clave, además, en `[A-Za-z0-9._-]`: el authInternal de MediaMTX rechaza «~» (enmienda del
// ADR 0022 del 2026-10-03).

import Foundation

public enum ProgramSrt {
    /// Ruta de MediaMTX donde publica el maestro. (Python: `PROGRAM_SRT_PATH` en
    /// tools/program_contract.py.)
    public static let path = "programa"

    /// Milisegundos de latencia SRT del programa al empezar una pasada: el margen de ARQ
    /// sobre 4G/5G (SPK-07, ADR 0023). El primer escalón de `latencyStepsMs`. (Python:
    /// `PROGRAM_SRT_LATENCY_MS`.)
    public static let latencyMs: Int32 = 1500

    /// Los escalones de latencia SRT, en ms, que el publicador sube cuando la red lo pide
    /// (2026-10-15, medido emitiendo al VPS por un Wi-Fi con bufferbloat: RTT de 1,2-2,8 s
    /// bajo carga contra 1500 ms de latencia, libsrt tirando por TLPKTDROP y el publicador
    /// reteniendo). Solo se aplica al conectar (SRTO_LATENCY): se sube al reconectar por
    /// atasco o cuando la conexión que acaba tuvo RTT o búfer de envío por encima de la mitad
    /// de la latencia. No baja sola en la pasada; la siguiente pasada empieza en el primero.
    /// El tope, 4000 ms, es el retardo cristal→VPS que se acepta antes que cortarse (hasta
    /// ~4,25 s en vez de los ~1,75 s de SPK-07; enmienda pendiente de decisión).
    public static let latencyStepsMs: [Int32] = [1500, 2500, 4000]

    /// Divisor de la latencia por encima del cual el RTT o el búfer de envío de una
    /// conexión dicen que esa latencia fue poca: la mitad. Con RTT > latencia/2 una sola
    /// retransmisión ya no llega a tiempo.
    public static let latencyRaiseDivisor: Int32 = 2

    /// Bytes por mensaje SRT: 7 paquetes TS de 188 B, la carga útil por defecto de SRT en
    /// modo live (SRTO_PAYLOADSIZE) y lo que espera MediaMTX.
    public static let payloadBytes = 1316

    /// Caracteres del streamid como mucho (ADR 0022 §1; el límite de SRTO_STREAMID).
    public static let maxStreamIdLength = 512

    /// Partes del streamid separadas por «:» que entiende MediaMTX: acción y ruta, más
    /// usuario y clave, más la query.
    public static let streamIdParts = 2...5

    /// Milisegundos que espera srt_connect a que conteste el servidor, por dirección.
    /// MediaMTX tarda 2 s en rechazar una clave mala (contra la fuerza bruta): con los 3 s
    /// por defecto de SRT, un RTT malo o un servidor cargado lo convertían en un timeout, y
    /// el publicador no sabría decir «clave mala». Es otra cosa que la cadencia de
    /// reconexión de IOS-56.
    public static let connectTimeoutMs: Int32 = 5000

    /// Longitud de la passphrase en caracteres: lo que acepta SRTO_PASSPHRASE.
    public static let passphraseLength = 10...79

    /// El alfabeto de usuario, clave y passphrase (ADR 0022 §2).
    static let credentialAlphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}

/// La latencia SRT en uso en una pasada y sus subidas (2026-10-15). Empieza en el primer
/// escalón (o en la que le den las pruebas) y sube por `ProgramSrt.latencyStepsMs` cuando el
/// publicador reconecta con la red pidiéndolo; nunca baja. El umbral de retención del
/// publicador (`congestionSendBufferMs`) sale de ella, no de una constante.
public struct ProgramSrtLatency: Equatable, Sendable, CustomStringConvertible {
    /// La latencia que lleva la próxima conexión (y la vigente, si está conectado), en ms.
    public private(set) var ms: Int32
    /// Veces que subió de escalón en la pasada.
    public private(set) var raises = 0

    public init(startMs: Int32 = ProgramSrt.latencyMs) {
        ms = startMs
    }

    /// Milisegundos del búfer de envío de SRT por encima de los que el publicador retiene:
    /// la mitad de la latencia en uso.
    public var congestionSendBufferMs: Int { ProgramPublish.congestionSendBufferMs(latencyMs: ms) }

    /// El escalón siguiente, si lo hay: el primero de la escalera mayor que la latencia en uso.
    public var nextMs: Int32? { ProgramSrt.latencyStepsMs.first { $0 > ms } }

    /// Queda un escalón por subir.
    public var canRaise: Bool { nextMs != nil }

    /// Sube al escalón siguiente. False en el tope: se queda como está.
    @discardableResult
    public mutating func raise() -> Bool {
        guard let siguiente = nextMs else { return false }
        ms = siguiente
        raises += 1
        return true
    }

    /// Si la conexión que acaba de cerrarse pidió más latencia: su RTT o su búfer de envío
    /// máximos pasaron de la mitad de la latencia con la que iba.
    public func sessionAsksForMore(rttMsMax: Double, sendBufferMsMax: Int) -> Bool {
        let umbral = ms / ProgramSrt.latencyRaiseDivisor
        return rttMsMax > Double(umbral) || sendBufferMsMax > Int(umbral)
    }

    /// «1,5 s», «2,5 s», «4 s»: para el log y la fila SRT de la pantalla.
    public var label: String { Self.label(ms: Int(ms)) }

    public static func label(ms: Int) -> String {
        let s = Double(ms) / 1000
        let texto = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s).replacingOccurrences(of: ".", with: ",")
        return "\(texto) s"
    }

    public var description: String { "latencia SRT \(label)" }
}

/// Por qué no vale un streamid o una credencial. Nunca lleva el valor: puede ser la clave.
public enum ProgramSrtError: Error, Equatable {
    case emptyField(String)
    case badCharacter(field: String)
    case tooLong(Int)
    case badPartCount(Int)
    case badPassphraseLength(Int)
}

/// El bloque `srt` del QR Soporte (ADR 0022 §3, NUBE-16): `{host, port, path, user, pass,
/// passphrase}`. Lo guarda el emparejado con el VPS (IOS-68) y lo usa el publicador (IOS-56).
public struct ProgramSrtTarget: Codable, Equatable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public let path: String
    public let user: String
    public let pass: String
    public let passphrase: String

    public init(host: String, port: UInt16, path: String = ProgramSrt.path,
                user: String, pass: String, passphrase: String) {
        self.host = host
        self.port = port
        self.path = path
        self.user = user
        self.pass = pass
        self.passphrase = passphrase
    }

    /// `publish:<ruta>:<usuario>:<clave>[:<query>]`, comprobado.
    public func streamId(query: String? = nil) throws -> String {
        try ProgramSrtStreamId.publish(path: path, user: user, pass: pass, query: query)
    }

    /// La passphrase, comprobada: de 10 a 79 caracteres del alfabeto.
    public func checkedPassphrase() throws -> String {
        guard ProgramSrt.passphraseLength.contains(passphrase.count) else {
            throw ProgramSrtError.badPassphraseLength(passphrase.count)
        }
        try ProgramSrtStreamId.check(passphrase, field: "passphrase", alphabet: ProgramSrt.credentialAlphabet)
        return passphrase
    }

    /// Para los logs: sin clave ni passphrase.
    public var description: String { "srt://\(host):\(port) publish:\(path):\(user):***" }
}

public enum ProgramSrtStreamId {
    /// La ruta y la query admiten más que las credenciales (`/`, `=`, `&`…), pero nunca «:»
    /// ni espacios: ASCII imprimible sin «:».
    static let freeAlphabet = Set((0x21...0x7E).map { Character(UnicodeScalar(UInt8($0))) }).subtracting([":"])

    /// `publish:<ruta>:<usuario>:<clave>[:<query>]`. Sin usuario ni clave, `publish:<ruta>`
    /// (el banco del Mac); el VPS siempre los pide.
    public static func publish(path: String, user: String? = nil, pass: String? = nil,
                               query: String? = nil) throws -> String {
        try check(path, field: "path", alphabet: freeAlphabet)
        var parts = ["publish", path]
        if user != nil || pass != nil {
            try check(user ?? "", field: "user", alphabet: ProgramSrt.credentialAlphabet)
            try check(pass ?? "", field: "pass", alphabet: ProgramSrt.credentialAlphabet)
            parts += [user ?? "", pass ?? ""]
        }
        if let query {
            try check(query, field: "query", alphabet: freeAlphabet)
            parts.append(query)
        }
        let id = parts.joined(separator: ":")
        guard id.count <= ProgramSrt.maxStreamIdLength else { throw ProgramSrtError.tooLong(id.count) }
        return id
    }

    /// Cualquier streamid, justo antes de enviarlo: de 2 a 5 partes no vacías, ASCII
    /// imprimible y 512 caracteres como mucho.
    public static func validate(_ id: String) throws {
        guard id.count <= ProgramSrt.maxStreamIdLength else { throw ProgramSrtError.tooLong(id.count) }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard ProgramSrt.streamIdParts.contains(parts.count) else {
            throw ProgramSrtError.badPartCount(parts.count)
        }
        for part in parts { try check(String(part), field: "streamid", alphabet: freeAlphabet) }
    }

    static func check(_ value: String, field: String, alphabet: Set<Character>) throws {
        guard !value.isEmpty else { throw ProgramSrtError.emptyField(field) }
        guard value.allSatisfy(alphabet.contains) else { throw ProgramSrtError.badCharacter(field: field) }
    }
}
