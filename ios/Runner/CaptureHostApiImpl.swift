// Puente entre el contrato generado por Pigeon y el motor de captura (TASK A2).
//
// Aquí no hay lógica: traduce llamadas y convierte errores en algo que se pueda leer en
// la pantalla del móvil, en la cancha. Cualquier decisión que se parezca a una regla va
// en `CaptureEngine` o en Dart.

import AVFoundation
import Flutter
import RigCore
import RigNet
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
    /// IOS-58: la pasada de EMITIR en la arquitectura B, entre startProgram y stopProgram.
    private var program: SplitBench?
    /// El medio del enlace de Network abierto, para el bitrate de la parte de EMITIR.
    private var linkMedium: LinkMedium?
    /// La pareja de fotogramas para calibrar (IOS-70), con el enlace de Network.
    private var calibPairs: CalibrationPairs?
    /// El lado del enlace de Network abierto.
    private var currentRole: CameraRole?

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
        ProgramHub.capture = self
        // IOS-103: el vídeo del mando acabó en el programa; el motor de Dart lo quita.
        VideoHub.shared.onEnded = { [weak self] id in
            Task { @MainActor in
                try? await self?.flutter.onVideoEnded(id: id)
            }
        }
        // 2026-10-14: un lanzamiento con RIG_LINK_SECRET lo guarda en el Keychain ya, al
        // arrancar. Antes solo se guardaba al abrir el enlace de Network (`startLink`): lanzar
        // con el secreto y cerrar sin abrir la cámara (el paso 2 de IOS-58) no guardaba nada.
        if ProcessInfo.processInfo.environment["RIG_LINK_SECRET"] != nil {
            let guardado = RigLinkNW.benchSecret() != nil
            NSLog("[enlace] secreto del soporte del entorno: %@", guardado ? "en el Keychain" : "NO VALE (no es base64)")
        }
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
                // Sin la URL en el mensaje: lleva la clave de las cámaras (IOS-68).
                throw PigeonError(code: "stream", message: "URL de emisión no válida", details: nil)
            }
            do {
                try engine.startStreaming(to: url)
            } catch {
                throw PigeonError(code: "stream", message: error.localizedDescription, details: nil)
            }
        }
        return path
    }

    /// Donde vivía el servidor antes de IOS-68: se muda al Keychain la primera vez que se lee.
    private static let legacyServerHostKey = "serverHost"

    func loadServerHost() throws -> String {
        if let host = try KeychainText.serverHost.read() {
            return host
        }
        guard let viejo = UserDefaults.standard.string(forKey: Self.legacyServerHostKey) else { return "" }
        try saveServerHost(host: viejo)
        return viejo
    }

    func saveServerHost(host: String) throws {
        if host.isEmpty {
            try KeychainText.serverHost.delete()
        } else {
            try KeychainText.serverHost.write(host)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyServerHostKey)
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

    // MARK: - Emparejado con el VPS por el QR Soporte (IOS-68, ADR 0022 §3)

    func loadVpsPairing() throws -> String {
        try KeychainText.vpsPairing.read() ?? ""
    }

    /// Solo entra en el Keychain un QR Soporte que se lee: el error dice qué campo falla,
    /// nunca su valor. La caducidad del `rig_key` la mira Dart al escanear.
    func saveVpsPairing(pairing: String) throws {
        do {
            _ = try VpsPairing.parse(pairing)
        } catch {
            throw PigeonError(code: "vps_pairing", message: "\(error)", details: nil)
        }
        try KeychainText.vpsPairing.write(pairing.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clearVpsPairing() throws {
        try KeychainText.vpsPairing.delete()
    }

    // MARK: - La API del mando en el maestro (IOS-62, IOS-63)

    func controlSecret(matchId: String) throws -> String {
        RigLinkNW.controlSecret(matchId: matchId)
    }

    func noteMandoState(json: String) throws {
        MandoHub.note(json: json)
    }

    func rigClockSnapshot() throws -> String {
        let host = RigLink.hostNowNs()
        let offset = linkSession?.clock.offsetAt(ns: host) ?? 0
        return #"{"rig_ns":\#(host + offset),"domain":"\#(RigClockDomain.current())"}"#
    }

    func adoptClockDomain(domain: String) throws {
        RigClockDomain.adopt(domain)
    }

    func sendReplica(json: String) throws {
        (link as? RigLinkNW)?.session.send(replica: Data(json.utf8))
    }

    func setMatchId(matchId: String) throws {
        linkSession?.matchId = matchId
    }

    /// La sesión del enlace de Network o la de «Una cámara»; nil con Multipeer o sin enlace.
    private var linkSession: RigLinkSession? {
        (link as? RigLinkNW)?.session ?? (link as? RigSoloLink)?.session
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

    /// Lo que pidió la pantalla (IOS-58), en el tipo de RigCore.
    private static func choice(_ mode: LinkMode) -> LinkChoice {
        switch mode {
        case .multipeer: .multipeer
        case .ethernet: .network(.ethernet)
        case .wifi: .network(.wifi)
        case .aware: .network(.aware)
        case .single: .single
        }
    }

    func startLink(role: CameraRole, prefersMaster: Bool, mode: LinkMode) throws {
        stopProgramRun()
        link?.stop()
        let link: PeerLinking
        // El entorno de los bancos (RIG_LINK_MULTIPEER, RIG_LINK_INTERFACE) manda; sin él,
        // lo elegido en la pantalla.
        guard let eleccion = LinkChoice.resolve(environment: ProcessInfo.processInfo.environment,
                                                requested: Self.choice(mode)) else {
            throw PigeonError(
                code: "link", message: "RIG_LINK_INTERFACE no es ethernet, wifi ni aware", details: nil
            )
        }
        switch eleccion {
        case .multipeer:
            engine.rigClock = nil
            AdHub.clock = nil
            linkMedium = nil
            link = RigLink(role: role)
        case .single:
            // «Una cámara (sin pareja)», 2026-10-15: sin enlace ni secreto. Este móvil es la
            // referencia del reloj del soporte (su host) y dirige desde ya.
            let solo = RigSoloLink(role: role)
            engine.rigClock = solo.clock
            AdHub.clock = solo.clock
            engine.setClockReference(true)
            linkMedium = nil
            calibPairs = nil
            currentRole = role
            solo.onRigRole = { [weak self] rol, term, partido in
                Task { @MainActor in
                    try? await self?.flutter.onRigRole(
                        role: rol == .master ? .master : .slave, term: Int64(term), matchId: partido
                    )
                }
            }
            ThumbHub.shared.start(
                side: role == .left ? .left : .right,
                pipeline: { [weak self] in self?.engine.rigPipeline }, session: solo.session
            )
            link = solo
        case let .network(medio):
            guard let secreto = RigLinkNW.benchSecret() else {
                throw PigeonError(
                    code: "link",
                    message: "sin secreto del soporte: lanza la app una vez desde el Mac con RIG_LINK_SECRET "
                        + "(se queda en el Keychain; IOS-97 lo pasará a un QR)",
                    details: nil
                )
            }
            linkMedium = medio
            let nw = RigLinkNW(role: role, secret: secreto, prefersMaster: prefersMaster, medium: medio)
            // IOS-13: la cámara lee el reloj nativo por fotograma, sin pasar por
            // Pigeon; a Dart solo le llega la estimación, para la pantalla y la fase.
            engine.rigClock = nw.clock
            // La franja, en el mismo reloj que el programa que la pide.
            AdHub.clock = nw.clock
            // Hasta que el enlace diga su rol, esclavo: la 4K espera al reloj (el rol
            // llega en cuanto arranca la sesión, antes que el primer fotograma grabado).
            engine.setClockReference(false)
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
            currentRole = role
            let pares = CalibrationPairs(session: nw.session, side: role == .left ? .left : .right, engine: engine)
            calibPairs = pares
            // IOS-80: el rol negociado sube a Dart, que deja de suponer que manda el
            // izquierdo; al dirigir, se arma el disparo automático de la calibración.
            let camara = engine
            nw.onRigRole = { [weak self, weak pares] rol, term, partido in
                if rol == .master { pares?.armAutoTrigger() }
                // El maestro es la referencia del reloj del soporte (ADR 0023 §4): su 4K
                // no espera; la del esclavo, a la estimación (RecordingClockGate).
                camara.setClockReference(rol == .master)
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
                let s = makeProgramRun(nw: nw, role: role,
                                       config: .bench(environment: ProcessInfo.processInfo.environment))
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
        stopProgramRun()
        split?.stop()
        split = nil
        engine.programLadderLevel = nil
        linkMedium = nil
        calibPairs = nil
        ThumbHub.shared.stop()
        link?.stop()
        link = nil
        engine.rigClock = nil
        AdHub.clock = nil
        engine.onLookLocked = nil
        engine.forgetMasterLook()
    }

    // MARK: - El programa (banco split e IOS-58)

    /// Una pasada del programa sobre el enlace de Network: el banco split o EMITIR. Junta
    /// SplitBench con la cámara (audio, 4K del banco, reloj) y el transporte del enlace.
    private func makeProgramRun(nw: RigLinkNW, role: CameraRole, config: ProgramRunConfig) -> SplitBench {
        let s = makeProgramRun(session: nw.session, role: role, config: config)
        s.linkStats = { [weak nw] in nw?.transportStats }
        s.linkDiagnosis = { [weak nw] in nw?.transportDiagnosis }
        s.linkEvents = { [weak nw] in nw?.transportTimeline }
        return s
    }

    /// La pasada del programa sobre una sesión: la del enlace de Network o, sin transporte,
    /// la de «Una cámara».
    private func makeProgramRun(session: RigLinkSession, role: CameraRole, config: ProgramRunConfig) -> SplitBench {
        let s = SplitBench(
            session: session, side: role == .left ? .left : .right,
            pipeline: { [weak self] in self?.engine.rigPipeline }, config: config
        )
        s.audioFormat = { [weak self] in self?.engine.audioFormatDescription }
        s.captureClockSkew = { [weak self] in self?.engine.clockSkewByMinuteMs ?? [] }
        s.cameraDrops = { [weak self] in
            guard let e = self?.engine else { return [:] }
            return ["out_of_buffers": e.cameraDropsOutOfBuffers, "late": e.cameraDropsLate, "other": e.cameraDropsOther]
        }
        s.cameraSwitch = { [weak self] on in self?.engine.setCameraRunningForBench(on) }
        s.exposureBias = { [weak self, weak s] ev in
            self?.engine.benchExposureBias(ev: ev) { r in s?.exposureApplied = r }
        }
        engine.onAacFrame = { [weak s] trama in s?.audio(trama) }
        // SPK-04 (RIG_SPLIT_RECORD_4K=1): la 4K local de la pasada, con su reserva.
        s.startLocal4K = { [weak self] carpeta, reserva in
            (try? self?.engine.startRecording(directory: carpeta, reserveBytes: reserva)) ?? ""
        }
        s.stopLocal4K = { [weak self] in self?.engine.stopRecording() }
        s.local4KFrames = { [weak self] in self?.engine.recordedFrames ?? 0 }
        s.local4KClock = { [weak self] in self?.engine.recordingClockReport() ?? [:] }
        // 2026-10-15: el spike de la duración de fotograma (RIG_SPIKE_FRAME_*).
        s.frameSpikeArm = { [weak self] fps in self?.engine.armFrameCadence(fps: fps) }
        s.frameDurationRequest = { [weak self] pedida, benchS, rigMs in
            self?.engine.benchFrameDuration(pedida, benchS: benchS, rigMs: rigMs)
        }
        s.frameSpikeReport = { [weak self] in self?.engine.frameSpikeReport() ?? [:] }
        s.audioReport = { [weak self] in self?.engine.audioReport() ?? [:] }
        // IOS-06: la escalera de la pasada lee los sensores de la cámara, actúa y es la que
        // enseña la pantalla mientras dura.
        s.ladderSensors = { [weak self] in self?.engine.ladderSensorTarget() ?? .l0 }
        engine.programLadderLevel = { [weak s] in s?.currentLadderLevel }
        return s
    }

    /// EMITIR (IOS-58): "" o por qué no. Una sola pasada a la vez; con el banco split en
    /// marcha no se mezcla otra. `output` solo cuenta con «Una cámara»: el soporte de dos va
    /// siempre a 1080p (IOS-99, ADR 0025).
    func startProgram(output: ProgramOutput) -> String {
        let solo = link as? RigSoloLink
        let nw = link as? RigLinkNW
        guard solo != nil || (nw != nil && linkMedium != nil) else {
            return "sin el enlace de Network: elige Wi-Fi, Wi-Fi Aware, Ethernet o «Una cámara» al abrir la cámara"
        }
        guard split == nil else { return "el banco split está en marcha" }
        guard program == nil else { return "" }
        guard let lado = currentRole else { return "sin lado" }
        // 2026-10-14: que la pantalla no se bloquee durante el partido, aunque una hoja del
        // sistema lo hubiera devuelto a su valor (también al volver a primer plano).
        UIApplication.shared.isIdleTimerDisabled = true
        engine.startRunning()
        let detector = SplitBench.productionDetector()
        let s: SplitBench
        if let solo {
            // «Una cámara (sin pareja)»: la misma pasada, de una sola lente.
            s = makeProgramRun(session: solo.session, role: lado,
                               config: .single(detectorPackage: detector, output: output))
        } else if let nw, let medio = linkMedium {
            s = makeProgramRun(nw: nw, role: lado, config: .production(medium: medio, detectorPackage: detector))
        } else {
            return "sin enlace"
        }
        s.start()
        program = s
        return ""
    }

    /// PARAR. El cierre (vaciar el codificador, cerrar la copia .mov, parar el SRT y
    /// escribir el informe) puede tardar segundos: va fuera del hilo principal, que es el
    /// del canal de Pigeon y el de la pantalla.
    func stopProgramRun() {
        guard let s = program else { return }
        program = nil
        engine.onAacFrame = nil
        engine.programLadderLevel = nil
        DispatchQueue.global(qos: .userInitiated).async { s.stop() }
    }

    func programStatus() -> ProgramStatus {
        program?.status() ?? SplitBench.idleStatus
    }

    /// IOS-14: el emparejado único por Wi-Fi Aware, con la hoja de DeviceDiscoveryUI.
    @MainActor
    func pairWithoutCable(role: CameraRole) async throws -> String {
        guard let encima = QrScanner.topViewController() else {
            throw PigeonError(code: "aware", message: "no hay pantalla sobre la que emparejar", details: nil)
        }
        do {
            return try await WiFiAwarePairing.pair(side: role == .left ? .left : .right, from: encima)
        } catch {
            throw PigeonError(code: "aware", message: "\(error)", details: nil)
        }
    }

    func masterRecentPtsNs() async throws -> [Int64] {
        await link?.masterRecentPts() ?? []
    }

    /// La capa de vista previa para la vista de plataforma `capture-preview`.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        engine.makePreviewLayer()
    }

    /// La app termina: la 4K se cierra si llega a tiempo (`LifecycleConstants`). Devuelve si
    /// llegó.
    func closeRecordingForTermination() -> Bool {
        engine.closeRecordingForTermination()
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

    /// El motivo del corte en palabras, para la pantalla y para los `app_events` del latido
    /// de la pasada. Los códigos son de `AVCaptureSession.InterruptionReason`.
    static func interruptionReason(_ notification: Notification) -> String {
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

/// El QR Soporte guardado, para quien publica o abre el túnel en nativo (IOS-56): su
/// `srt` es el `ProgramSrtTarget` del programa. `nil` si no hay; no mira la caducidad del
/// `rig_key`, que no afecta al SRT.
enum VpsPairingKeychain {
    static func load() throws -> VpsPairing? {
        guard let texto = try KeychainText.vpsPairing.read() else { return nil }
        return try VpsPairing.parse(texto)
    }
}

/// Por dónde llega `RigHostApi` a la pasada del programa (IOS-58): la cámara y el enlace
/// viven en CaptureHostApiImpl, y el contrato del pipeline es el de RigHostApi.
enum ProgramHub {
    static weak var capture: CaptureHostApiImpl?
}

/// El estado del mando del maestro para el latido y el informe de la emisión (Bug A,
/// 2026-10-21): el QR que no salía no dejaba rastro. Dart manda el suyo al cambiar
/// (`serving`, `port`, `match_id`, `addresses`, `can_pair`, `problem`); de dónde sale la
/// clave (`rig`, `device`…) lo pone `RigLinkNW.controlSecret`. Cada cambio va también a los
/// `app_events` de la pasada que esté en marcha.
enum MandoHub {
    private static let lock = NSLock()
    private static var state: [String: Any] = [:]
    private static var keyOrigin = ""

    static func note(json: String) {
        guard let datos = json.data(using: .utf8),
              let estado = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any]
        else { return }
        lock.lock()
        state = estado
        lock.unlock()
        let linea = summary(estado)
        NSLog("[mando] %@", linea)
        NotificationCenter.default.post(name: .mandoStateChanged, object: nil, userInfo: ["text": linea])
    }

    static func note(keyOrigin origen: String) {
        lock.lock()
        keyOrigin = origen
        lock.unlock()
    }

    /// Lo último que se sabe, con `key`: lo que va al latido y al informe.
    static func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var d = state
        if !keyOrigin.isEmpty { d["key"] = keyOrigin }
        return d
    }

    /// Una línea para los `app_events`: dónde sirve o por qué no.
    static func summary(_ estado: [String: Any]) -> String {
        if estado["serving"] as? Bool == true {
            let ips = (estado["addresses"] as? [String]) ?? []
            let puerto = estado["port"] as? Int ?? 0
            return "mando: sirve en " + (ips.isEmpty ? "ninguna IPv4 de la LAN" : ips.joined(separator: ", "))
                + " puerto \(puerto)" + ((estado["can_pair"] as? Bool) == true ? "" : ", sin clave para el QR")
        }
        return "mando: no sirve" + ((estado["problem"] as? String).map { ": \($0)" } ?? "")
    }
}

extension Notification.Name {
    /// Un cambio del estado del mando (`MandoHub`); `userInfo["text"]` lo resume.
    static let mandoStateChanged = Notification.Name("football-ai.mando.state")
}

/// Un texto en el Keychain: el QR «Mando» (ADR 0017 de football-ai), el PIN del operador
/// (IOS-62), el QR «Soporte» del VPS y el servidor del pod (IOS-68).
///
/// `ThisDeviceOnly`: mueven el marcador o publican en nombre del soporte, y no pueden irse
/// en la copia de seguridad a otro iPhone; sin `kSecAttrSynchronizable`, tampoco al
/// llavero de iCloud. `AfterFirstUnlock`: se leen con la pantalla bloqueada tras el
/// primer desbloqueo, que es como vive el móvil en la banda. Ojo: el Keychain sobrevive a
/// desinstalar la app; para olvidarlos están los `clear…` y `saveOperatorPin("")`.
///
/// El QR Soporte va en `football-ai.vps` / `soporte`, en UTF-8, el JSON del QR tal cual
/// (sin espacios alrededor): es el formato que leen IOS-56 e IOS-65.
struct KeychainText {
    static let panelPairing = KeychainText(account: "panel", what: "el emparejamiento con el panel")
    static let operatorPin = KeychainText(account: "pin-operador", what: "el PIN del operador")
    static let vpsPairing = KeychainText(service: "football-ai.vps", account: "soporte",
                                         what: "el emparejado con el VPS")
    static let serverHost = KeychainText(service: "football-ai.servidor", account: "host",
                                         what: "el servidor")
    /// El secreto del soporte S en base64 (ADR 0023 §3), hasta el QR de IOS-97 (IOS-58).
    static let linkSecret = KeychainText(service: "football-ai.enlace", account: "secreto",
                                         what: "el secreto del soporte")
    /// El secreto propio del mando de este móvil en base64, para cuando no tiene S (Bug A,
    /// 2026-10-21; `ControlKeySource`). Nunca sale del móvil ni al log.
    static let deviceControlSecret = KeychainText(service: "football-ai.enlace", account: "secreto-mando-propio",
                                                  what: "el secreto propio del mando")

    var service = "football-ai.mando"
    let account: String
    let what: String

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
