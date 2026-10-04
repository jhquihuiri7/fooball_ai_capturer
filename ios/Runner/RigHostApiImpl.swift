// La mitad nativa del contrato del pipeline (IOS-08).
//
// Fina a propósito: el trabajo vive en ZeroKit (BenchRunner), que se prueba con
// `swift test` en el Mac. Aquí solo se cruza el canal.

import Flutter
import Foundation
import RigMedia

final class RigHostApiImpl: NSObject, RigHostApi {
    private let flutter: RigFlutterApi

    init(binaryMessenger: FlutterBinaryMessenger) {
        flutter = RigFlutterApi(binaryMessenger: binaryMessenger)
        super.init()
        RigHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: self)
    }

    func runBench(name: String, paramsJson: String) async throws -> String {
        let flutter = self.flutter
        let informe = try await Task.detached(priority: .userInitiated) {
            let progreso: BenchRunner.Progress = { fraction, detail in
                Task { @MainActor in
                    try? await flutter.onBenchProgress(name: name, fraction: fraction, detail: detail)
                }
            }
            // El banco del enlace vive en el Runner: junta RigNet con el informe.
            if name == "link-bench" {
                return try LinkBench.run(progress: progreso)
            }
            return try BenchRunner.run(name: name, paramsJson: paramsJson) { fraction, detail in
                Task { @MainActor in
                    try? await flutter.onBenchProgress(name: name, fraction: fraction, detail: detail)
                }
            }
        }.value
        return informe.path
    }
}
