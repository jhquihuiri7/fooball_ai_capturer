// El escritor del registro N0 en el móvil (IOS-75): un JSONL por partido y por móvil.
//
// Como MatchLogWriter de la referencia (EV-02): la cabecera al abrir, los registros a
// una cola acotada que se vacía a disco cada MATCH_LOG_FLUSH_LINES líneas en una cola
// propia, y si la cola se llena se descarta y se cuenta (nunca se bloquea a quien
// registra: el pipeline va a 30 fps). Es la copia que queda si no hay internet.

import Foundation
import RigCore

public enum MatchLogConstants {
    /// Líneas entre dos vaciados a disco (`MATCH_LOG_FLUSH_LINES`).
    public static let flushLines = 50
    /// Líneas que espera la cola como mucho (`MATCH_LOG_QUEUE_MAX`).
    public static let queueMax = 1024
}

public final class E0Logger {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private let io = DispatchQueue(label: "io.footballai.zero.e0", qos: .utility)
    private var pending: [String] = []
    private var flushing = false
    public private(set) var written = 0
    public private(set) var dropped = 0

    public enum E0Error: Error, Equatable {
        case clockDomain(String)
    }

    /// El `clock_domain` de la cabecera (ADR 0023 §4), lo que valida read_match_log.
    static let clockDomainPattern = try! NSRegularExpression(pattern: "^[a-z0-9]{8,32}$")

    /// Abre (o crea) el fichero y escribe la cabecera si está vacío. Una cabecera que el
    /// validador de la referencia rechazaría no se escribe.
    public init(url: URL, header: MatchLogRecord) throws {
        if case let .header(_, _, dominio, _, _, _, _, _) = header,
           Self.clockDomainPattern.firstMatch(in: dominio, range: NSRange(dominio.startIndex..., in: dominio)) == nil {
            throw E0Error.clockDomain("`clock_domain` tiene que ser [a-z0-9]{8,32} (ADR 0023 §4): \(dominio)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        let fin = try handle.seekToEnd()
        if fin == 0 {
            handle.write(Data((header.line + "\n").utf8))
        }
    }

    deinit {
        try? handle.close()
    }

    /// Apunta un registro. No bloquea: con la cola llena, se descarta y se cuenta.
    public func log(_ record: MatchLogRecord) {
        lock.lock()
        guard pending.count < MatchLogConstants.queueMax else {
            dropped += 1
            lock.unlock()
            return
        }
        pending.append(record.line)
        let vaciar = pending.count >= MatchLogConstants.flushLines && !flushing
        if vaciar { flushing = true }
        lock.unlock()
        if vaciar { io.async { [self] in drain() } }
    }

    /// Vacía lo que haya y espera a que esté en disco (al cerrar el partido o en tests).
    public func flush() {
        io.sync { drain() }
    }

    private func drain() {
        lock.lock()
        let lote = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        if !lote.isEmpty {
            handle.write(Data((lote.joined(separator: "\n") + "\n").utf8))
        }
        lock.lock()
        written += lote.count
        flushing = false
        lock.unlock()
    }
}
