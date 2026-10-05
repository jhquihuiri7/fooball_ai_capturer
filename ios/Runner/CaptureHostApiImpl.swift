// Puente entre el contrato generado por Pigeon y el motor de captura (TASK A2).
//
// Aquí no hay lógica: traduce llamadas y convierte errores en algo que se pueda leer en
// la pantalla del móvil, en la cancha. Cualquier decisión que se parezca a una regla va
// en `CaptureEngine` o en Dart.

import AVFoundation
import Flutter
import Security

final class CaptureHostApiImpl: NSObject, CaptureHostApi {
    private let engine = CaptureEngine()
    private let flutter: CaptureFlutterApi

    /// IOS-07: brillo mientras se emite. No es cero: con cero, en la cancha parece un
    /// móvil apagado y alguien lo «enciende». Lo que había se guarda y se restaura.
    private static let dimmedScreenBrightness: CGFloat = 0.05
    private var brightnessBeforeDim: CGFloat?

    func setScreenDim(dimmed: Bool) throws {
        if dimmed {
            if brightnessBeforeDim == nil {
                brightnessBeforeDim = UIScreen.main.brightness
            }
            UIScreen.main.brightness = Self.dimmedScreenBrightness
        } else if let previo = brightnessBeforeDim {
            UIScreen.main.brightness = previo
            brightnessBeforeDim = nil
        }
    }

    /// El enlace con el otro móvil del soporte. Se crea al preparar la cámara.
    private var link: PeerLinking?
    /// El banco program-split, si se lanzó con RIG_SPLIT=1.
    private var split: SplitBench?
    /// La pareja de fotogramas para calibrar (IOS-70), con el enlace de Network.
    private var calibPairs: CalibrationPairs?

    /// RIG_LINK_MULTIPEER=0 cambia al enlace nuevo sobre Network (IOS-12). El Multipeer
    /// de hoy sigue siendo el predeterminado hasta la aceptación de campo con hubs.
    private static var useMultipeer: Bool {
        ProcessInfo.processInfo.environment["RIG_LINK_MULTIPEER"] != "0"
    }

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

    func start(srtUrl: String, recordingDirectory: String, saveVideo: Bool) throws -> String {
        // Por si la cámara se quedó parada (una interrupción que no se recuperó, por
        // ejemplo): sin frames no hay ni grabación ni emisión, y no se ve por qué.
        engine.startRunning()
        let directory = recordingDirectory.isEmpty ? defaultDirectory : recordingDirectory
        var path = ""
        if saveVideo {
            do {
                // El orden importa: primero el fichero, después la emisión. Si algo falla,
                // que falle lo prescindible (ADR 0012, decisión 5).
                path = try engine.startRecording(directory: directory)
            } catch {
                throw PigeonError(code: "record", message: error.localizedDescription, details: nil)
            }
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
        try KeychainText.panelPairing.read() ?? ""
    }

    func savePanelPairing(pairing: String) throws {
        try KeychainText.panelPairing.write(pairing)
    }

    func clearPanelPairing() throws {
        try KeychainText.panelPairing.delete()
    }

    // MARK: - La API del mando en el maestro (IOS-62, IOS-63)

    func controlSecret(matchId: String) throws -> String {
        RigLinkNW.controlSecret(matchId: matchId) ?? ""
    }

    func rigClockSnapshot() throws -> String {
        let host = RigLink.hostNowNs()
        let offset = (link as? RigLinkNW)?.clock.offsetAt(ns: host) ?? 0
        return #"{"rig_ns":\#(host + offset),"domain":"\#(RigClockDomain.current())"}"#
    }

    func adoptClockDomain(domain: String) throws {
        RigClockDomain.adopt(domain)
    }

    func sendReplica(json: String) throws {
        (link as? RigLinkNW)?.session.send(replica: Data(json.utf8))
    }

    func setMatchId(matchId: String) throws {
        (link as? RigLinkNW)?.matchId = matchId
    }

    func linkPeerAddress() throws -> String {
        (link as? RigLinkNW)?.peerHost ?? ""
    }

    func captureCalibrationPairs() async throws -> String {
        guard let pares = calibPairs else {
            return #"{"error":"sin enlace de Network"}"#
        }
        return await withCheckedContinuation { c in pares.start { c.resume(returning: $0) } }
    }

    func loadOperatorPin() throws -> String {
        try KeychainText.operatorPin.read() ?? ""
    }

    func saveOperatorPin(pin: String) throws {
        if pin.isEmpty {
            try KeychainText.operatorPin.delete()
        } else {
            try KeychainText.operatorPin.write(pin)
        }
    }

    // MARK: - Enlace entre móviles (TASK A3, A4)

    func startLink(role: CameraRole, prefersMaster: Bool) throws {
        link?.stop()
        let link: PeerLinking
        if Self.useMultipeer {
            engine.rigClock = nil
            link = RigLink(role: role)
        } else {
            guard let secreto = RigLinkNW.benchSecret() else {
                throw PigeonError(
                    code: "link",
                    message: "sin secreto de enlace: define RIG_LINK_SECRET (IOS-97 lo llevará al Keychain)",
                    details: nil
                )
            }
            let nw = RigLinkNW(role: role, secret: secreto, prefersMaster: prefersMaster)
            // IOS-13: la cámara lee el reloj nativo por fotograma, sin pasar por
            // Pigeon; a Dart solo le llega la estimación, para la pantalla y la fase.
            engine.rigClock = nw.clock
            nw.onClockEstimate = { [weak self] estimate in
                Task { @MainActor in
                    try? await self?.flutter.onClockEstimate(
                        offsetNs: estimate.offsetNs,
                        driftPpm: estimate.driftPpm,
                        samples: Int64(estimate.samples),
                        uncertaintyNs: estimate.uncertaintyNs
                    )
                }
            }
            link = nw
            let pares = CalibrationPairs(session: nw.session, side: role == .left ? .left : .right, engine: engine)
            calibPairs = pares
            // IOS-80: el rol negociado sube a Dart, que deja de suponer que manda el
            // izquierdo; al dirigir, se arma el disparo automático de la calibración.
            nw.onRigRole = { [weak self, weak pares] rol, term, partido in
                if rol == .master { pares?.armAutoTrigger() }
                Task { @MainActor in
                    try? await self?.flutter.onRigRole(
                        role: rol == .master ? .master : .slave, term: Int64(term), matchId: partido
                    )
                }
            }
            nw.session.onReplica = { [weak self] datos in
                let json = String(decoding: datos, as: UTF8.self)
                Task { @MainActor in try? await self?.flutter.onReplica(json: json) }
            }
            ThumbHub.shared.start(
                side: role == .left ? .left : .right,
                pipeline: { [weak self] in self?.engine.rigPipeline }, session: nw.session
            )
            if SplitBench.enabled() {
                let s = SplitBench(
                    session: nw.session, side: role == .left ? .left : .right,
                    pipeline: { [weak self] in self?.engine.rigPipeline }
                )
                s.audioFormat = { [weak self] in self?.engine.audioFormatDescription }
                engine.onAacFrame = { [weak s] trama in s?.audio(trama) }
                s.start()
                split = s
            }
        }
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
            // Las órdenes del maestro se ejecutan en Dart, que es quien sabe con qué URL
            // emitir y en qué carpeta grabar.
            link.onCommand = { [weak self] command in
                Task { @MainActor in
                    try? await self?.flutter.onPeerCommand(command: command)
                }
            }
        }
        self.link = link
        link.start()
    }

    func sendPeerCommand(command: RigCommand) throws {
        link?.send(command: command)
    }

    func stopLink() throws {
        split?.stop()
        split = nil
        calibPairs = nil
        ThumbHub.shared.stop()
        link?.stop()
        link = nil
        engine.rigClock = nil
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

    func releaseCamera() throws {
        engine.releaseCamera()
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

/// Un texto en el Keychain: el QR «Mando» (ADR 0017 de football-ai) o el PIN del
/// operador (IOS-62).
///
/// `ThisDeviceOnly`: los dos mueven el marcador de un partido y no pueden irse en la copia
/// de seguridad a otro iPhone. `AfterFirstUnlock`: se leen con la pantalla bloqueada tras
/// el primer desbloqueo, que es como vive el móvil en la banda. Ojo: el Keychain
/// sobrevive a desinstalar la app; para olvidarlos están `clearPanelPairing` y
/// `saveOperatorPin("")`.
private struct KeychainText {
    static let panelPairing = KeychainText(account: "panel", what: "el emparejamiento con el panel")
    static let operatorPin = KeychainText(account: "pin-operador", what: "el PIN del operador")

    let account: String
    let what: String

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "football-ai.mando",
            kSecAttrAccount as String: account,
        ]
    }

    func read() throws -> String? {
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

    func write(_ text: String) throws {
        let data = Data(text.utf8)
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

    func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status, "borrar")
        }
    }

    private func failure(_ status: OSStatus, _ action: String) -> PigeonError {
        PigeonError(
            code: "keychain",
            message: "no se pudo \(action) \(what) (\(status))",
            details: nil
        )
    }
}
