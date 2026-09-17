// Puente entre el contrato generado por Pigeon y el motor de captura (TASK A2).
//
// Aquí no hay lógica: traduce llamadas y convierte errores en algo que se pueda leer en
// la pantalla del móvil, en la cancha. Cualquier decisión que se parezca a una regla va
// en `CaptureEngine` o en Dart.
//
// NO COMPILADO. Se escribió en Windows: no ha pasado por Xcode ni por un dispositivo.

import AVFoundation
import Flutter

final class CaptureHostApiImpl: NSObject, CaptureHostApi {
    private let engine = CaptureEngine()
    private let flutter: CaptureFlutterApi

    /// Dónde graba si Dart no dice otra cosa. `Documents` para que las grabaciones se
    /// puedan sacar por Finder sin instalar nada, que es lo que se va a querer hacer
    /// cuando la emisión se degrade y el archivo sea el partido bueno.
    private lazy var defaultDirectory: String = {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    }()

    init(binaryMessenger: FlutterBinaryMessenger) {
        flutter = CaptureFlutterApi(binaryMessenger: binaryMessenger)
        super.init()
        CaptureHostApiSetup.setUp(binaryMessenger: binaryMessenger, api: self)
        observeInterruptions()
    }

    // MARK: - CaptureHostApi

    func requestCameraAccess() async throws -> Bool {
        // Con el permiso ya decidido responde al instante; si no, iOS enseña el diálogo
        // y la respuesta llega cuando el operador pulsa. Se pide aquí, en vez de dejar
        // que lo dispare la sesión al abrirse, porque en ese caso la cámara arranca sin
        // entregar frames y nadie se entera.
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestLocalNetworkAccess() async throws -> Bool {
        await LocalNetworkAccess.request()
    }

    func hasUltraWideCamera() throws -> Bool {
        engine.hasUltraWideCamera()
    }

    func configure(settings: CaptureSettings) async throws -> CaptureStatus {
        do {
            _ = try await engine.configure(settings)
            return engine.status()
        } catch {
            throw PigeonError(
                code: "configure",
                message: error.localizedDescription,
                details: nil
            )
        }
    }

    func start(srtUrl: String, recordingDirectory: String) throws -> String {
        let directory = recordingDirectory.isEmpty ? defaultDirectory : recordingDirectory
        let path: String
        do {
            // El orden importa: primero el fichero, después la emisión. Si algo falla,
            // que falle lo prescindible (ADR 0012, decisión 5).
            path = try engine.startRecording(directory: directory)
        } catch {
            throw PigeonError(code: "record", message: error.localizedDescription, details: nil)
        }

        if !srtUrl.isEmpty {
            guard let url = URL(string: srtUrl) else {
                throw PigeonError(code: "stream", message: "URL de emisión no válida: \(srtUrl)", details: nil)
            }
            do {
                try engine.startStreaming(to: url)
            } catch {
                throw PigeonError(code: "stream", message: error.localizedDescription, details: nil)
            }
        }
        return path
    }

    private static let serverHostKey = "serverHost"

    func loadServerHost() throws -> String {
        UserDefaults.standard.string(forKey: Self.serverHostKey) ?? ""
    }

    func saveServerHost(host: String) throws {
        UserDefaults.standard.set(host, forKey: Self.serverHostKey)
    }

    func discoverServer() async throws -> String {
        await ServerDiscovery.find()
    }

    /// La capa de vista previa para la vista de plataforma `capture-preview`.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        engine.makePreviewLayer()
    }

    func stop() throws {
        engine.stop()
    }

    func status() throws -> CaptureStatus {
        engine.status()
    }

    func recentFramePtsNs() throws -> [Int64] {
        engine.recentFramePtsNs()
    }

    func restartForPhase() throws {
        engine.restartForPhase()
    }

    func setClockOffsetNs(offsetNs: Int64) throws {
        engine.setClockOffsetNs(offsetNs)
    }

    // MARK: - Avisos hacia Flutter

    /// Una llamada entrante, otra app tomando la cámara o el sistema recortando por
    /// calor interrumpen la sesión. Sin esto, la app se queda con una pantalla bonita y
    /// sin grabar, y nadie se entera hasta el descanso.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            Task { @MainActor in
                try? await self?.flutter.onInterrupted(reason: "motivo \(reason ?? -1)")
            }
        }
        center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await self?.flutter.onResumed()
            }
        }
        center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let state = self.engine.status().thermalState
            Task { @MainActor in
                try? await self.flutter.onThermalStateChanged(state: state)
            }
        }
    }
}
