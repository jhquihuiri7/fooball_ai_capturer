// La mitad nativa del contrato del pipeline (IOS-08).
//
// Fina a propósito: el trabajo vive en ZeroKit (BenchRunner), que se prueba con
// `swift test` en el Mac. Aquí solo se cruza el canal.

import Flutter
import Foundation
import Metal
import RigMedia

/// El gráfico del programa del móvil (IOS-47): uno, a tamaño de programa, que llena
/// Dart por `setOverlay` y lee la composición del maestro.
enum OverlayHub {
    static let programWidth = 1920
    static let programHeight = 1080
    static let shared: OverlayStore? = MTLCreateSystemDefaultDevice().flatMap {
        OverlayStore(device: $0, width: programWidth, height: programHeight)
    }
}

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

    func setOverlay(
        rgba: FlutterStandardTypedData, width: Int64, height: Int64, x: Int64, y: Int64,
        layer: Int64, generation: Int64
    ) throws {
        guard let capa = OverlayLayer(rawValue: Int(layer)) else {
            throw PigeonError(code: "overlay", message: "capa desconocida: \(layer)", details: nil)
        }
        OverlayHub.shared?.set(
            capa, rgba: [UInt8](rgba.data),
            rect: .init(x: Int(x), y: Int(y), width: Int(width), height: Int(height)),
            generation: Int(generation)
        )
    }

    func clearOverlay(layer: Int64) throws {
        guard let capa = OverlayLayer(rawValue: Int(layer)) else { return }
        OverlayHub.shared?.clear(capa)
    }
}
