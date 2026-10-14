// El socket SRT del programa (IOS-55): un envoltorio fino sobre la API C de libsrt, en modo
// caller y live, para publicar el MPEG-TS del maestro en el MediaMTX del VPS (ADR 0022).
//
// - El streamid se comprueba ANTES de enviarlo (ProgramSrtStreamId): MediaMTX escribe en su
//   log el que no entiende, con la clave dentro.
// - SRTO_LATENCY = ProgramSrt.latencyMs (1500 ms de partida; SPK-07 lo fija).
// - SRTO_PASSPHRASE: la del QR Soporte (ProgramSrtTarget), que IOS-68 guarda en el Keychain.
//   Aquí no se guarda ni se escribe en ningún log.
// - El envío no bloquea: trozos de ProgramSrt.payloadBytes (1316 B) y, si el búfer de envío
//   de SRT está lleno, `send` devuelve lo que entró. Qué hacer con el resto (descartar hasta
//   el siguiente IDR) es del publicador (IOS-56).
// - `stats()` es srt_bstats, para la telemetría y el bitrate adaptativo.
//
// No es seguro entre hilos: lo usa una sola cola, la del publicador.

import CSrt
import Darwin
import Foundation
import RigCore

/// Por qué falló SRT. Nunca lleva el streamid ni la passphrase.
public enum SrtError: Error, Equatable, CustomStringConvertible {
    /// El streamid o la passphrase no valen: no se llega a enviar nada.
    case invalid(ProgramSrtError)
    case resolve(String)
    case option(String, String)
    case timeout
    /// srt_getrejectreason: un SRT_REJ_* (<1000) o el código del servidor (≥1000).
    case rejected(Int32)
    case connect(Int32, String)
    case send(Int32, String)
    case notConnected

    /// La passphrase no cuadra con la del otro lado (libsrt en escucha).
    public static let rejectBadSecret = Int32(truncatingIfNeeded: SRT_REJ_BADSECRET.rawValue)
    /// Un lado cifra y el otro no (libsrt en escucha).
    public static let rejectUnsecure = Int32(truncatingIfNeeded: SRT_REJ_UNSECURE.rawValue)
    /// El servidor rechaza sin decir por qué. Es lo que contesta MediaMTX 1.21 tanto a una
    /// passphrase mala como a un usuario o clave malos (su log sí lo distingue).
    public static let rejectPeer = Int32(truncatingIfNeeded: SRT_REJ_PEER.rawValue)

    public var description: String {
        switch self {
        case .invalid(let e): return "streamid o passphrase no válidos: \(e)"
        case .resolve(let host): return "no se resuelve \(host)"
        case .option(let name, let msg): return "SRT no acepta \(name): \(msg)"
        case .timeout: return "SRT: sin respuesta del servidor"
        case .rejected(let r): return "SRT rechazado: \(String(cString: csrt_rejectreason_str(r))) (\(r))"
        case .connect(let code, let msg): return "SRT no conecta (\(code)): \(msg)"
        case .send(let code, let msg): return "SRT no envía (\(code)): \(msg)"
        case .notConnected: return "SRT sin conectar"
        }
    }
}

/// Lo que da srt_bstats del lado que envía. Los totales, desde que se conectó.
public struct SrtStats: Equatable, Sendable, CustomStringConvertible {
    public var msTimeStamp: Int64
    public var packetsSent: Int64
    public var bytesSent: UInt64
    public var packetsLost: Int32
    public var packetsRetransmitted: Int32
    public var packetsDropped: Int32
    public var sendRateMbps: Double
    public var bandwidthMbps: Double
    public var rttMs: Double
    public var sendBufferPackets: Int32
    public var sendBufferBytes: Int32
    public var sendBufferMs: Int32
    public var flightPackets: Int32

    init(_ s: SRT_TRACEBSTATS) {
        msTimeStamp = s.msTimeStamp
        packetsSent = s.pktSentTotal
        bytesSent = s.byteSentTotal
        packetsLost = s.pktSndLossTotal
        packetsRetransmitted = s.pktRetransTotal
        packetsDropped = s.pktSndDropTotal
        sendRateMbps = s.mbpsSendRate
        bandwidthMbps = s.mbpsBandwidth
        rttMs = s.msRTT
        sendBufferPackets = s.pktSndBuf
        sendBufferBytes = s.byteSndBuf
        sendBufferMs = s.msSndBuf
        flightPackets = s.pktFlightSize
    }

    public var description: String {
        String(format: "%lld paq (%llu B) · perdidos %d · retx %d · tirados %d · %.2f Mbit/s · "
               + "rtt %.0f ms · búfer %d paq / %d ms",
               packetsSent, bytesSent, packetsLost, packetsRetransmitted, packetsDropped,
               sendRateMbps, rttMs, sendBufferPackets, sendBufferMs)
    }
}

public final class SrtSocket {
    private var sock: SRTSOCKET = SRT_INVALID_SOCK

    public init() {}

    deinit { close() }

    /// Conecta con el destino del QR Soporte: `publish:<ruta>:<usuario>:<clave>[:<query>]` y
    /// su passphrase, las dos comprobadas antes de salir.
    public func connect(to target: ProgramSrtTarget, query: String? = nil,
                        latencyMs: Int32 = ProgramSrt.latencyMs,
                        timeoutMs: Int32 = ProgramSrt.connectTimeoutMs) throws {
        let streamId: String, passphrase: String
        do {
            streamId = try target.streamId(query: query)
            passphrase = try target.checkedPassphrase()
        } catch let e as ProgramSrtError {
            throw SrtError.invalid(e)
        }
        try connect(host: target.host, port: target.port, streamId: streamId,
                    passphrase: passphrase, latencyMs: latencyMs, timeoutMs: timeoutMs)
    }

    /// Conecta en modo caller. Bloquea hasta conectar, hasta `timeoutMs` por dirección o hasta
    /// que el servidor rechace. Prueba las direcciones del host en orden (IPv6 e IPv4).
    public func connect(host: String, port: UInt16, streamId: String, passphrase: String?,
                        latencyMs: Int32 = ProgramSrt.latencyMs,
                        timeoutMs: Int32 = ProgramSrt.connectTimeoutMs) throws {
        do {
            try ProgramSrtStreamId.validate(streamId)
        } catch let e as ProgramSrtError {
            throw SrtError.invalid(e)
        }
        if let passphrase, !ProgramSrt.passphraseLength.contains(passphrase.utf8.count) {
            throw SrtError.invalid(.badPassphraseLength(passphrase.utf8.count))
        }
        close()
        SrtLibrary.start()
        var lastError = SrtError.resolve(host)
        for address in try Self.resolve(host: host, port: port) {
            let s = csrt_create_socket()
            guard s != SRT_INVALID_SOCK else { throw Self.lastError(SrtError.connect) }
            do {
                try Self.set(s, SRTO_TRANSTYPE, Int32(truncatingIfNeeded: SRTT_LIVE.rawValue), "SRTO_TRANSTYPE")
                try Self.set(s, SRTO_SNDSYN, false, "SRTO_SNDSYN")
                try Self.set(s, SRTO_CONNTIMEO, timeoutMs, "SRTO_CONNTIMEO")
                try Self.set(s, SRTO_LATENCY, latencyMs, "SRTO_LATENCY")
                try Self.setString(s, SRTO_STREAMID, streamId, "SRTO_STREAMID")
                if let passphrase { try Self.setString(s, SRTO_PASSPHRASE, passphrase, "SRTO_PASSPHRASE") }
                let r = address.withUnsafeBytes {
                    csrt_connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count))
                }
                if r != SRT_ERROR {
                    sock = s
                    return
                }
                let code = csrt_getlasterror(nil)
                if code == SRT_ECONNREJ.rawValue {
                    let reason = csrt_getrejectreason(s)
                    // Sin respuesta llega como rechazo por timeout: se prueba la siguiente.
                    if reason != Int32(truncatingIfNeeded: SRT_REJ_TIMEOUT.rawValue) {
                        throw SrtError.rejected(reason)
                    }
                    lastError = .timeout
                } else if code == SRT_ENOSERVER.rawValue {
                    lastError = .timeout
                } else {
                    lastError = .connect(code, String(cString: csrt_getlasterror_str()))
                }
                csrt_close(s)
            } catch {
                csrt_close(s)
                throw error
            }
        }
        throw lastError
    }

    public var isConnected: Bool {
        sock != SRT_INVALID_SOCK && csrt_getsockstate(sock) == SRTS_CONNECTED
    }

    /// Envía sin bloquear, en mensajes de 1316 B. Devuelve los bytes que entraron: menos que
    /// `data.count` si el búfer de envío de SRT está lleno (la congestión de IOS-56). Lanza si
    /// la conexión se ha roto.
    public func send(_ data: Data) throws -> Int {
        guard sock != SRT_INVALID_SOCK else { throw SrtError.notConnected }
        return try data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
            var sent = 0
            while sent < raw.count {
                let n = min(ProgramSrt.payloadBytes, raw.count - sent)
                if csrt_sendmsg2(sock, base + sent, Int32(n), nil) == SRT_ERROR {
                    let code = csrt_getlasterror(nil)
                    if code == SRT_EASYNCSND.rawValue { break }
                    throw SrtError.send(code, String(cString: csrt_getlasterror_str()))
                }
                sent += n
            }
            return sent
        }
    }

    /// srt_bstats. Con `clear`, los contadores de intervalo vuelven a cero (los totales no).
    public func stats(clear: Bool = false) throws -> SrtStats {
        guard sock != SRT_INVALID_SOCK else { throw SrtError.notConnected }
        var s = SRT_TRACEBSTATS()
        guard csrt_bstats(sock, &s, clear ? 1 : 0) != SRT_ERROR else {
            throw Self.lastError(SrtError.connect)
        }
        return SrtStats(s)
    }

    public func close() {
        guard sock != SRT_INVALID_SOCK else { return }
        csrt_close(sock)
        sock = SRT_INVALID_SOCK
    }

    // MARK: - C

    private static func resolve(host: String, port: UInt16) throws -> [Data] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw SrtError.resolve(host)
        }
        defer { freeaddrinfo(first) }
        var out: [Data] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let addr = ai.pointee.ai_addr { out.append(Data(bytes: addr, count: Int(ai.pointee.ai_addrlen))) }
            p = ai.pointee.ai_next
        }
        return out
    }

    private static func set<T: BitwiseCopyable>(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, _ value: T,
                                                _ name: String) throws {
        let r = withUnsafeBytes(of: value) { csrt_setsockflag(s, opt, $0.baseAddress, Int32($0.count)) }
        guard r != SRT_ERROR else {
            throw SrtError.option(name, String(cString: csrt_getlasterror_str()))
        }
    }

    private static func setString(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, _ value: String, _ name: String) throws {
        let bytes = Array(value.utf8)
        guard csrt_setsockflag(s, opt, bytes, Int32(bytes.count)) != SRT_ERROR else {
            throw SrtError.option(name, String(cString: csrt_getlasterror_str()))
        }
    }

    private static func lastError(_ make: (Int32, String) -> SrtError) -> SrtError {
        make(csrt_getlasterror(nil), String(cString: csrt_getlasterror_str()))
    }
}
