// Los informes de MetricKit (IOS-05): lo que iOS cuenta del día anterior.
//
// MXMetricManager entrega una vez al día (y al reabrir tras un cuelgue) métricas de
// energía, memoria, cuelgues y excepciones. Se guardan tal cual en Documents/metrics/:
// son el complemento barato del remojo térmico (M19) que nadie tiene que recordar
// encender. Solo existe en iOS: en el Mac el símbolo se compila fuera.

#if canImport(MetricKit) && os(iOS)

import Foundation
import MetricKit
import os

public final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let log = Logger(subsystem: Signposts.subsystem, category: "metrickit")
    private let directory: URL

    /// Se crea una vez al arrancar la app y se retiene. `directory` por defecto:
    /// Documents/metrics/.
    public init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("metrics", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        store(payloads.map { $0.jsonRepresentation() }, prefix: "metrics")
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        store(payloads.map { $0.jsonRepresentation() }, prefix: "diagnostics")
    }

    private func store(_ payloads: [Data], prefix: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        for (indice, data) in payloads.enumerated() {
            let sello = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
            let url = directory.appendingPathComponent("\(prefix)-\(sello)-\(indice).json")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("no se pudo guardar \(prefix): \(String(describing: error))")
            }
        }
    }
}

#endif
