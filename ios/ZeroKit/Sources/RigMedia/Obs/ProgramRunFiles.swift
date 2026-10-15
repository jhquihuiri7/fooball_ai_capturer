// Los ficheros de una pasada del programa (el banco split y EMITIR) en Documents/bench: el
// latido y el informe final (2026-10-15).
//
// El esclavo del plan B de la cancha (`bench/partido-20261015-0902`) no se enlazó nunca y al
// acabar no dejó informe: SplitBench.finish solo lo escribía si el móvil era maestro o había
// montado su parte, y un esclavo sin enlace no la monta. Su último latido decía
// `finished: false` y la recogida lo dio por una app muerta. Aquí se escriben los dos, el
// informe y el latido con `finished: true`, sea cual sea el rol y haya enlace o no.

import Foundation

public enum ProgramRunFiles {
    /// El informe final: `program-split-<lado>-<hora Unix al acabar>.json`.
    public static func reportName(side: String, endUnixS: Int64) -> String {
        "program-split-\(side)-\(endUnixS).json"
    }

    /// El latido, uno por pasada: `program-live-<lado>-<hora Unix del arranque>.json`.
    public static func liveName(side: String, startUnixMs: Int64) -> String {
        "program-live-\(side)-\(startUnixMs / msPerSecond).json"
    }

    /// Sin números que JSON no admite: un percentil desbordado da infinito y
    /// `JSONSerialization` aborta la app (le pasó al esclavo promovido el 6-oct). Lo no
    /// finito pasa a -1.
    public static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : -1.0
        case let f as Float: return f.isFinite ? Double(f) : -1.0
        case let m as [String: Any]: return m.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        default: return v
        }
    }

    /// Un informe o un latido en JSON, ordenado y legible.
    public static func encode(_ informe: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonSafe(informe), options: [.sortedKeys, .prettyPrinted])
    }

    /// El cierre de la pasada, en `directory` (se crea si falta): el informe final y el latido
    /// con `finished: true`, siempre los dos. El latido va el último: quien lo lea ya
    /// encuentra el informe. Devuelve dónde quedaron.
    @discardableResult
    public static func writeFinal(
        report: [String: Any], live: [String: Any], directory: URL, side: String, startUnixMs: Int64, endUnixS: Int64
    ) throws -> (report: URL, live: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let informe = directory.appendingPathComponent(reportName(side: side, endUnixS: endUnixS))
        try encode(report).write(to: informe, options: .atomic)
        var latido = live
        latido["finished"] = true
        let vivo = directory.appendingPathComponent(liveName(side: side, startUnixMs: startUnixMs))
        try encode(latido).write(to: vivo, options: .atomic)
        return (informe, vivo)
    }

    static let msPerSecond: Int64 = 1000
}
