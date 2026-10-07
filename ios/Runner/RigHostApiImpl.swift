// La mitad nativa del contrato del pipeline (IOS-08).
//
// Fina a propósito: el trabajo vive en ZeroKit (BenchRunner), que se prueba con
// `swift test` en el Mac. Aquí solo se cruza el canal.

import Flutter
import Foundation
import Metal
import RigCore
import RigMedia

/// El gráfico del programa del móvil (IOS-47): uno, a tamaño de programa, que llena
/// Dart por `setOverlay` y lee la composición del maestro.
/// La franja de anuncios del móvil (IOS-48): la llena Dart (o el banco) y la lee la
/// composición del maestro.
enum AdHub {
    static let store: AdStore? = MTLCreateSystemDefaultDevice().map {
        AdStore(device: $0, width: OverlayHub.programWidth, height: OverlaySpec.stripHeight)
    }
    static let rotation: AdRotation? = store.map { AdRotation(store: $0) }

    /// El instante del soporte en el maestro (su reloj de host).
    static func nowRigMs() -> Int64 { RigLink.hostNowNs() / 1_000_000 }

    /// Carga la lista: los anuncios de Documents/ads/<dir> y sus vueltas.
    static func apply(json: String) throws {
        guard let store, let rotation,
              let raiz = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                  .appendingPathComponent("ads", isDirectory: true),
              let datos = json.data(using: .utf8),
              let doc = try JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else {
            throw PigeonError(code: "ads", message: "lista de anuncios ilegible", details: nil)
        }
        for ad in doc["ads"] as? [[String: Any]] ?? [] {
            guard let nombre = ad["name"] as? String else { continue }
            let fps = (ad["fps"] as? Int) ?? 30
            if let frames = ad["frames"] as? [String] {
                // El paquete del VPS (IOS-49): un PNG por fotograma, repetidos.
                guard !frames.contains(where: { $0.contains("..") }) else { continue }
                try store.loadFiles(frames.map { raiz.appendingPathComponent($0) }, name: nombre, fps: fps)
            } else if let dir = ad["dir"] as? String, !dir.contains("..") {
                try store.loadDirectory(raiz.appendingPathComponent(dir), name: nombre, fps: fps)
            }
        }
        let slots = try (doc["slots"] as? [[String: Any]] ?? []).compactMap { slot -> AdSlot? in
            guard let nombre = slot["name"] as? String, let clip = store.clip(named: nombre) else { return nil }
            return try AdSlot(ad: clip, loops: (slot["loops"] as? Int) ?? 1)
        }
        rotation.set(playlist: AdPlaylist(slots: slots), atRigMs: nowRigMs())
    }
}

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

    func setAdPlaylist(json: String) throws -> String {
        do {
            try AdHub.apply(json: json)
            return ""
        } catch {
            return "\(error)"
        }
    }

    func thumbnail(name: String) throws -> FlutterStandardTypedData {
        FlutterStandardTypedData(bytes: ThumbHub.shared.jpeg(name) ?? Data())
    }

    func setAdOverride(name: String, loops: Int64) throws {
        let clip = name.isEmpty ? nil : AdHub.store?.clip(named: name)
        AdHub.rotation?.set(override: clip, loops: max(1, Int(loops)), atRigMs: AdHub.nowRigMs())
    }

    func clearOverlay(layer: Int64) throws {
        guard let capa = OverlayLayer(rawValue: Int(layer)) else { return }
        OverlayHub.shared?.clear(capa)
    }
}
