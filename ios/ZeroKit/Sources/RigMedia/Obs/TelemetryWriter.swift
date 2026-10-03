// El escritor de telemetría (IOS-05): una línea JSONL por segundo en
// Documents/telemetry/, por cola acotada.
//
// El camino caliente solo encola (y si la cola se llena, descarta y cuenta: la
// telemetría es sacrificable, el vídeo no). Una cola serie propia drena al fichero.

import Foundation
import os
import RigCore

public final class TelemetryWriter {
    /// Fotos en vuelo como máximo: a 1 Hz, ocho segundos de atasco de disco antes de
    /// empezar a tirar. Más sería esconder un disco enfermo.
    private static let queueCapacity = 8

    private let log = Logger(subsystem: Signposts.subsystem, category: "telemetry")
    private let worker = DispatchQueue(label: "io.footballai.zero.telemetry", qos: .utility)
    private let lock = NSLock()
    private var pending = BoundedQueue<Data>(capacity: TelemetryWriter.queueCapacity, policy: .dropOldest)
    private var handle: FileHandle?

    public let fileURL: URL
    public private(set) var dropped = 0
    public private(set) var written = 0

    /// Con `drainsAutomatically` en falso nadie escribe hasta `flush()`: es el modo de
    /// los tests, que así ven la cola acotada sin carreras.
    private let drainsAutomatically: Bool

    /// `directory` por defecto: Documents/telemetry/. El fichero lleva el arranque de
    /// la sesión en el nombre, uno por sesión.
    public init(
        directory: URL? = nil,
        sessionStart: Date = Date(),
        drainsAutomatically: Bool = true
    ) throws {
        self.drainsAutomatically = drainsAutomatically
        let base = try directory ?? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let nombre = "telemetry-\(formatter.string(from: sessionStart).replacingOccurrences(of: ":", with: "")).jsonl"
        fileURL = base.appendingPathComponent(nombre)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
    }

    deinit {
        try? handle?.close()
    }

    /// Encola una foto. Vuelve enseguida: el disco es cosa de la cola de utilidad.
    public func append(_ snapshot: TelemetrySnapshot) {
        let data: Data
        do {
            data = try snapshot.jsonLine()
        } catch {
            log.error("foto incodificable: \(String(describing: error))")
            return
        }
        lock.lock()
        if pending.push(data) != nil {
            dropped += 1
        }
        lock.unlock()
        if drainsAutomatically {
            worker.async { [weak self] in self?.drainNow() }
        }
    }

    /// Escribe lo pendiente y devuelve cuántas líneas salieron. Para el cierre de
    /// sesión y los tests. Siempre drena por la cola serie: un solo hilo escribe.
    @discardableResult
    public func flush() -> Int {
        worker.sync { drainNow() }
    }

    /// Solo corre en `worker`: es lo que hace que el fichero lo toque un hilo.
    @discardableResult
    private func drainNow() -> Int {
        var escritas = 0
        while true {
            lock.lock()
            let siguiente = pending.pop()
            lock.unlock()
            guard let data = siguiente else { break }
            write(line: data)
            escritas += 1
        }
        lock.lock()
        written += escritas
        lock.unlock()
        return escritas
    }

    private func write(line: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            log.error("no se pudo escribir la telemetría: \(String(describing: error))")
        }
    }
}
