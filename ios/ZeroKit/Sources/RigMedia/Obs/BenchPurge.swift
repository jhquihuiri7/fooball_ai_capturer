// Borrar las pruebas viejas del móvil al arrancar, con RIG_PURGE_BENCH=1 (2026-10-15,
// `tools/limpiar_moviles.sh --borrar-pruebas`).
//
// Los bancos llenan Documents (en el iPhone 17, el 2026-10-15: bench/ 41 GB, bench4k/ 18 GB y
// nv12/ 6 GB) y la 4K del plan B pide 42,5 GB libres al arrancar. `devicectl` no sabe borrar
// ficheros del contenedor de una app: lista, copia, instala y desinstala la app entera (que se
// llevaría rig.json, los modelos y el secreto). Así que borra la app, una vez, si se la lanza
// con la variable.
//
// Solo dentro de `bench/`, `bench4k/` y `nv12/`, y solo los ficheros modificados antes de hoy
// (el comienzo del día en el calendario del móvil): lo de antes ya se recogió en el Mac o no
// hace falta. Nunca rig.json, bench-resources/, calib/, n0/, las copias program-*.mov de
// EMITIR ni nada fuera de esas tres carpetas. Los enlaces simbólicos no se siguen ni se borran.
// Deja su informe en `bench/purge-<hora Unix>.json`: así el guion del Mac sabe que acabó.
//
// Con RIG_PURGE_COPIES=1 además (2026-10-25, `--borrar-copias`), las copias locales de antes de
// hoy de la raíz de Documents: las del programa (`program-*.mov`, ~2 GB por hora de EMITIR) y
// las 4K (`left-*.mov`, `right-*.mov`). El 24-oct eran 34 GB en el 17 y ayudaron a llenar el
// disco que tumbó la emisión. El VPS graba el programa.

import Foundation
import RigCore

public enum BenchPurge {
    /// La variable de entorno del lanzamiento que la pide.
    public static let environmentKey = "RIG_PURGE_BENCH"

    /// La que pide, además, las copias locales de la raíz de Documents.
    public static let copiesEnvironmentKey = "RIG_PURGE_COPIES"

    /// La clave de esas copias en el informe (no es una carpeta: es la raíz).
    public static let copiesKey = "copias"

    /// Si un fichero de la raíz de Documents es una copia local: la del programa o una 4K.
    public static func isLocalCopy(_ name: String) -> Bool {
        RecordingPolicy.isProgramCopy(name)
            || ((name.hasPrefix("left-") || name.hasPrefix("right-")) && name.hasSuffix(".mov"))
    }

    /// Las carpetas de Documents que se limpian: informes y vídeos de los bancos, las 4K de
    /// las pasadas y los volcados NV12.
    public static let folders = ["bench", "bench4k", "nv12"]

    /// Lo que se borró de una carpeta.
    public struct FolderResult: Equatable {
        public var removedFiles = 0
        public var removedBytes: Int64 = 0
        public var keptFiles = 0
    }

    public struct Report: Equatable {
        public var cutoff: Date
        public var byFolder: [String: FolderResult]
        /// Lo que no se pudo borrar, con el motivo.
        public var failures: [String]

        public var removedFiles: Int { byFolder.values.reduce(0) { $0 + $1.removedFiles } }
        public var removedBytes: Int64 { byFolder.values.reduce(0) { $0 + $1.removedBytes } }
    }

    /// Lo de antes de hoy: lo modificado antes del comienzo del día de `now`.
    public static func cutoff(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    /// Si el lanzamiento lo pide, borra y deja el informe; si no, nil sin tocar nada.
    @discardableResult
    public static func purgeIfAsked(environment: [String: String], documents: URL, now: Date,
                                    calendar: Calendar = .current) -> Report? {
        guard environment[environmentKey] == "1" else { return nil }
        let report = run(documents: documents, cutoff: cutoff(now: now, calendar: calendar),
                         copies: environment[copiesEnvironmentKey] == "1")
        do {
            try writeReport(report, documents: documents, now: now)
        } catch {
            NSLog("[purge] sin informe: %@", "\(error)")
        }
        NSLog("[purge] %d ficheros, %lld bytes de antes de hoy", report.removedFiles, report.removedBytes)
        return report
    }

    /// Borra de `folders` los ficheros normales modificados antes de `cutoff` y las
    /// subcarpetas que se quedan vacías (no las tres carpetas: los bancos escriben ahí). Con
    /// `copies`, también las copias locales de antes de `cutoff` de la raíz (`isLocalCopy`).
    public static func run(documents: URL, cutoff: Date, copies: Bool = false,
                           fileManager: FileManager = .default) -> Report {
        var report = Report(cutoff: cutoff, byFolder: [:], failures: [])
        let claves: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                        .contentModificationDateKey, .fileSizeKey]
        for folder in folders {
            var result = FolderResult()
            let raiz = documents.appendingPathComponent(folder, isDirectory: true)
            var carpetas: [URL] = []
            if let todo = fileManager.enumerator(at: raiz, includingPropertiesForKeys: claves) {
                for case let url as URL in todo {
                    guard let v = try? url.resourceValues(forKeys: Set(claves)) else { continue }
                    if v.isSymbolicLink == true {
                        result.keptFiles += 1
                        continue
                    }
                    if v.isDirectory == true {
                        carpetas.append(url)
                        continue
                    }
                    guard v.isRegularFile == true else { continue }
                    guard let fecha = v.contentModificationDate, fecha < cutoff else {
                        result.keptFiles += 1
                        continue
                    }
                    do {
                        try fileManager.removeItem(at: url)
                        result.removedFiles += 1
                        result.removedBytes += Int64(v.fileSize ?? 0)
                    } catch {
                        result.keptFiles += 1
                        report.failures.append("\(folder)/\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            // De la más honda a la menos: una carpeta vacía tras borrar sus hijas también se va.
            for carpeta in carpetas.sorted(by: { $0.path.count > $1.path.count }) {
                if let dentro = try? fileManager.contentsOfDirectory(atPath: carpeta.path), dentro.isEmpty {
                    try? fileManager.removeItem(at: carpeta)
                }
            }
            report.byFolder[folder] = result
        }
        if copies {
            report.byFolder[copiesKey] = purgeCopies(documents: documents, cutoff: cutoff, keys: claves,
                                                     fileManager: fileManager, failures: &report.failures)
        }
        return report
    }

    /// Las copias locales de la raíz de Documents (sin bajar a ninguna carpeta).
    private static func purgeCopies(documents: URL, cutoff: Date, keys: [URLResourceKey], fileManager: FileManager,
                                    failures: inout [String]) -> FolderResult {
        var result = FolderResult()
        let urls = (try? fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: keys)) ?? []
        for url in urls where isLocalCopy(url.lastPathComponent) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  v.isRegularFile == true
            else { continue }
            guard let fecha = v.contentModificationDate, fecha < cutoff else {
                result.keptFiles += 1
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                result.removedFiles += 1
                result.removedBytes += Int64(v.fileSize ?? 0)
            } catch {
                result.keptFiles += 1
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// `bench/purge-<hora Unix>.json`: el corte, lo borrado por carpeta y los fallos.
    @discardableResult
    public static func writeReport(_ report: Report, documents: URL, now: Date) throws -> URL {
        let bench = documents.appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: bench, withIntermediateDirectories: true)
        var porCarpeta: [String: Any] = [:]
        for (folder, r) in report.byFolder {
            porCarpeta[folder] = ["removed_files": r.removedFiles, "removed_bytes": r.removedBytes,
                                  "kept_files": r.keptFiles]
        }
        let contenido: [String: Any] = [
            "name": "purge",
            "cutoff_unix_s": Int64(report.cutoff.timeIntervalSince1970),
            "removed_files": report.removedFiles,
            "removed_bytes": report.removedBytes,
            "by_folder": porCarpeta,
            "failures": report.failures,
        ]
        let destino = bench.appendingPathComponent("purge-\(Int64(now.timeIntervalSince1970)).json")
        try ProgramRunFiles.encode(contenido).write(to: destino, options: .atomic)
        return destino
    }
}
