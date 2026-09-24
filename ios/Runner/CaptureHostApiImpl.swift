// Puente entre el contrato generado por Pigeon y el motor de captura (TASK A2).
//
// Aquí no hay lógica: traduce llamadas y convierte errores en algo que se pueda leer en
// la pantalla del móvil, en la cancha. Cualquier decisión que se parezca a una regla va
// en `CaptureEngine` o en Dart.
//
// NO COMPILADO. Se escribió en Windows: no ha pasado por Xcode ni por un dispositivo.

import AVFoundation
import Flutter
import Security

final class CaptureHostApiImpl: NSObject, CaptureHostApi {
    private let engine = CaptureEngine()
    private let flutter: CaptureFlutterApi

    /// El enlace con el otro móvil del soporte. Se crea al preparar la cámara.
    private var link: RigLink?

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

    func scanServerQr() async throws -> String {
        await QrScanner.scan()
    }

    // MARK: - Emparejamiento con el panel como mando (ADR 0017 de football-ai)

    func loadPanelPairing() throws -> String {
        try PanelPairingKeychain.read() ?? ""
    }

    func savePanelPairing(pairing: String) throws {
        try PanelPairingKeychain.write(pairing)
    }

    func clearPanelPairing() throws {
        try PanelPairingKeychain.delete()
    }

    // MARK: - Enlace entre móviles (TASK A3, A4)

    func startLink(role: CameraRole) throws {
        link?.stop()
        let link = RigLink(role: role)
        // El maestro contesta con los PTS de su propia cámara, ya en tiempo del soporte.
        link.recentPts = { [weak self] in self?.engine.recentFramePtsNs() ?? [] }
        link.onState = { [weak self] state, peer in
            Task { @MainActor in
                try? await self?.flutter.onLinkStateChanged(state: state, peerName: peer)
            }
        }
        link.onStamps = { [weak self] t1, t2, t3, t4 in
            Task { @MainActor in
                try? await self?.flutter.onClockStamps(t1Ns: t1, t2Ns: t2, t3Ns: t3, t4Ns: t4)
            }
        }
        // Mismo color en las dos mitades: el izquierdo dice cómo ve y el derecho lo copia.
        if role == .left {
            link.currentLook = { [weak self] in self?.engine.look() }
            engine.onLookLocked = { [weak link] look in link?.publish(look: look) }
        } else {
            link.onLook = { [weak self] look in self?.engine.adopt(masterLook: look) }
            engine.onLookLocked = nil
        }
        self.link = link
        link.start()
    }

    func stopLink() throws {
        link?.stop()
        link = nil
        engine.onLookLocked = nil
        engine.forgetMasterLook()
    }

    func masterRecentPtsNs() async throws -> [Int64] {
        await link?.masterRecentPts() ?? []
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
            guard let self else { return }
            self.engine.interruptionBegan()
            let reason = Self.interruptionReason(notification)
            Task { @MainActor in
                try? await self.flutter.onInterrupted(reason: reason)
            }
        }
        center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.interruptionEnded()
            Task { @MainActor in
                try? await self.flutter.onResumed()
            }
        }
        center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            NSLog("[capture] error de sesión: %@", error?.localizedDescription ?? "?")
            self.engine.runtimeErrorOccurred()
            Task { @MainActor in
                try? await self.flutter.onInterrupted(
                    reason: "error de la cámara: \(error?.localizedDescription ?? "desconocido")"
                )
            }
        }
        center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.thermalStateChanged()
            let state = self.engine.status().thermalState
            Task { @MainActor in
                try? await self.flutter.onThermalStateChanged(state: state)
            }
        }
    }

    /// El motivo del corte en palabras, para la pantalla. Los códigos son de
    /// `AVCaptureSession.InterruptionReason`.
    private static func interruptionReason(_ notification: Notification) -> String {
        guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        else {
            return "motivo desconocido"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "la app pasó a segundo plano"
        case .audioDeviceInUseByAnotherClient: return "otra app usa el micrófono"
        case .videoDeviceInUseByAnotherClient: return "otra app usa la cámara"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "pantalla compartida"
        case .videoDeviceNotAvailableDueToSystemPressure: return "el sistema recortó la cámara por calor"
        case .sensitiveContentMitigationActivated: return "protección de contenido del sistema"
        @unknown default: return "motivo \(raw)"
        }
    }
}

/// El texto del QR «Mando», en el Keychain (ADR 0017 de football-ai).
///
/// `ThisDeviceOnly`: el token mueve el marcador de un partido y no puede irse en la copia
/// de seguridad a otro iPhone. `AfterFirstUnlock`: se lee con la pantalla bloqueada tras
/// el primer desbloqueo, que es como vive el móvil en la banda. Ojo: el Keychain
/// sobrevive a desinstalar la app; para olvidar el panel está `clearPanelPairing`.
private enum PanelPairingKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "football-ai.mando",
        kSecAttrAccount as String: "panel",
    ]

    static func read() throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw failure(status, "leer")
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ pairing: String) throws {
        let data = Data(pairing.utf8)
        var status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw failure(status, "guardar")
        }
    }

    static func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status, "borrar")
        }
    }

    private static func failure(_ status: OSStatus, _ action: String) -> PigeonError {
        PigeonError(
            code: "keychain",
            message: "no se pudo \(action) el emparejamiento con el panel (\(status))",
            details: nil
        )
    }
}
