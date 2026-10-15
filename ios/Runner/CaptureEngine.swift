// La sesión de captura: cámara, grabación local y sellos en tiempo del soporte.
// (ADR 0012, TASK A2 y A8.)
//
// Dos cosas que este fichero hace y que una app de cámara normal no haría:
//
//   1. **Reescribe el PTS de cada frame.** El sello que sale al disco y al stream no es
//      el del reloj de este iPhone, sino el del soporte: el local más el desfase que
//      Dart estimó contra el otro móvil. Es lo que permite que el servidor empareje por
//      marca de tiempo sin saber nada de relojes (ADR 0012, decisión 2).
//   2. **Graba siempre en local mientras emite.** La emisión es best-effort sobre un
//      enlace que pierde paquetes cada 15 segundos; el fichero es la verdad (decisión 5).

import AVFoundation
import CallKit
import RigCore
import RigMedia
import UIKit

final class CaptureEngine: NSObject {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.footballai.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()

    private var device: AVCaptureDevice?
    private var applied: AppliedCameraSettings?
    private var settings: CaptureSettings?
    private var stabilizationOff = false
    private var intrinsicsAvailable = false

    private let publisher = StreamPublisher()

    // IOS-06: los sensores y la escalera. Sin pasada del programa, la escalera de aquí solo
    // se enseña; con el banco split o EMITIR, actúa la de la pasada (SplitBench con
    // LadderGovernor), que lee estos sensores y es la que se enseña.
    private let thermalMonitor = ThermalMonitor()
    private var ladder = DegradationLadder()
    /// El nivel de la escalera de la pasada del programa en marcha, si la hay.
    var programLadderLevel: (() -> LadderLevel?)?

    // IOS-09: el enganche del pipeline. Copia cada fotograma al anillo propio sin
    // retener más de un búfer de la cámara; sus consumidores llegan con IOS-23+.
    private var pipeline: RigPipeline?

    // IOS-54: el micrófono en la misma sesión. El programa lleva siempre su AAC: el del
    // micro si hay permiso y, si no o mientras otro cliente lo tenga (una llamada), el
    // silencio del vigilante (AudioCapture.keepAlive). RIG_AUDIO=0 lo quita del todo (los
    // bancos «sin micro»); RIG_AUDIO=1 además deja las tramas en
    // Documents/bench/audio-<t>.aac con su informe.
    private let audioOutput = AVCaptureAudioDataOutput()
    /// El primer fotograma visto (instante en el host y separación entre relojes), en ns.
    private var clockSkewStart: (atNs: Int64, skewNs: Int64)?
    /// La separación entre el reloj de la sesión y el del host, minuto a minuto, en ms.
    private(set) var clockSkewByMinuteMs: [Double] = []
    private static let nsPerMinute: Int64 = 60_000_000_000
    private let audioQueue = DispatchQueue(label: "io.footballai.capture.audio", qos: .userInitiated)
    private var audio: AudioCapture?
    private var audioFile: FileHandle?
    private var audioURL: URL?
    private var audioFrames = 0
    /// La entrada del micro, mientras está en la sesión. Se toca en la cola de captura (y
    /// en `configure`, con la sesión aún sin arrancar).
    private var micInput: AVCaptureDeviceInput?
    /// Permiso de micro concedido: se pregunta en `configure`.
    private var micAllowed = false
    /// Otro cliente tomó el micro y se quitó de la sesión para que el vídeo siga.
    private var micSuspended = false
    /// El vigilante del AAC, en la cola del audio.
    private var silenceTimer: DispatchSourceTimer?
    /// Las llamadas en curso: con una, el micro no se intenta recuperar.
    private let callObserver = CXCallObserver()
    private var audioObservers: [NSObjectProtocol] = []
    /// El programa lleva AAC (con micro o con silencio). Lo mira también el banco.
    static let audioEnabled = ProcessInfo.processInfo.environment["RIG_AUDIO"] != "0"
    /// Las tramas AAC, además, a un fichero del banco (se mira en cada trama: una vez).
    private static let audioBenchFile = ProcessInfo.processInfo.environment["RIG_AUDIO"] == "1"

    /// El pipeline, para los bancos que cuelgan etapas de él (program-split).
    var rigPipeline: RigPipeline? { pipeline }
    private var ladderSteppedAt = CMClockGetTime(CMClockGetHostTimeClock())

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    /// La pista de audio de la 4K (IOS-57), si hay micro: el PCM se codifica en AAC.
    private var audioWriterInput: AVAssetWriterInput?
    private var writerStarted = false

    /// Lo que hace falta para reabrir la grabación en un segmento nuevo tras un corte:
    /// que el operador quería grabar, dónde, y cuántos segmentos van.
    private var recordingWanted = false
    private var recordingDirectory = ""

    /// Qué hacer con cada fotograma de la 4K según el reloj del soporte: esperar a que
    /// valga y cortar el segmento si salta (RecordingClockGate; el esclavo de SPK-04 del
    /// 2026-10-11 grabó 592 497 s en 10 min). Vive en la cola de captura.
    private var clockGate = RecordingClockGate()
    /// Si este móvil es la referencia del reloj del soporte (el maestro, ADR 0023 §4). Lo
    /// fija el enlace con cada rol negociado; vive en la cola de captura.
    private var isClockReference = false

    /// El segmento en curso y la copia de la puerta, para leerlos fuera de la cola de
    /// captura: el segmento cambia también en ella, al cortar por un salto del reloj.
    private let recordingLock = NSLock()
    private var segmentNumber = 0
    private var segmentFile = ""
    private var clockGateSnapshot = RecordingClockGate()

    var recordingSegment: Int {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return segmentNumber
    }

    var recordingFile: String {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return segmentFile
    }

    /// Lo que la puerta del reloj hizo con la 4K en curso.
    var recordingClock: RecordingClockGate {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return clockGateSnapshot
    }

    /// Exposición y balance del maestro, si han llegado por el enlace. Se guardan porque
    /// pueden llegar antes de que esta cámara esté configurada.
    private var masterLook: CameraLook?

    /// Avisa de que esta cámara acaba de congelar exposición y balance: el maestro lo
    /// usa para pasárselos al otro móvil.
    var onLookLocked: ((CameraLook) -> Void)?

    /// Desfase al tiempo del soporte, en nanosegundos. Lo fija Dart.
    private var clockOffsetNs: Int64 = 0

    /// El reloj nativo del soporte (IOS-13), cuando el enlace corre sobre Network. Si
    /// está, manda sobre `clockOffsetNs`: extrapola la deriva por fotograma. RigClock
    /// lleva su propio cerrojo, así que se lee desde la cola de la cámara sin más.
    var rigClock: RigClock?

    /// IOS-15: el volcado NV12 para medir el salto de dominio, solo en modo banco.
    /// Se activa lanzando con NV12_DUMP_S=<segundos> en el entorno (devicectl), igual
    /// que el secreto del enlace: no hay interruptor en la pantalla a propósito.
    private lazy var nv12Dumper: Nv12Dumper? = {
        guard let valor = ProcessInfo.processInfo.environment["NV12_DUMP_S"],
              let intervalo = Double(valor), intervalo > 0
        else {
            return nil
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Nv12Dumper(
            directory: documents.appendingPathComponent("nv12"),
            side: ProcessInfo.processInfo.environment["NV12_DUMP_SIDE"] ?? "left",
            intervalS: intervalo
        )
    }()

    /// Últimos PTS entregados, en tiempo del soporte. Es lo que Dart resta contra los
    /// del otro móvil para medir la fase de exposición (TASK A4).
    private var recentPts: [Int64] = []
    private let recentPtsCapacity = 30

    private(set) var droppedFrames: Int64 = 0
    /// 2026-10-14: los descartes de la cámara por su motivo (didDrop). «Sin búferes» dice
    /// que alguien retuvo los de su pool, que entonces crece y no vuelve a bajar: una de
    /// las sospechas del salto de +180 MB del maestro en el ensayo de 90 min.
    private(set) var cameraDropsOutOfBuffers: Int64 = 0
    private(set) var cameraDropsLate: Int64 = 0
    private(set) var cameraDropsOther: Int64 = 0
    /// Fotogramas que entraron a la 4K desde que arrancó la app (el banco de SPK-04).
    private(set) var recordedFrames: Int64 = 0

    // 2026-10-15: el spike de la duración de fotograma (RIG_SPIKE_FRAME_*, solo bancos; la
    // propuesta del ADR 0024 de football-ai). El banco split lo arma y pide las duraciones;
    // aquí se aplican como en `lockSettings` y se mide lo que da la cámara. Se toca en la
    // cola de captura; el informe se lee fuera, tras `frameSpikeLock`.
    private struct FrameSpikeTransition {
        var info: [String: Any]
        var effect: FrameDurationEffect
    }

    /// Armado: cada fotograma pasa por la cadencia. Solo en la cola de captura.
    private var frameSpikeArmed = false
    private let frameSpikeLock = NSLock()
    /// La duración nominal, la de `lockSettings` (1/fps); la fija quien arma el spike.
    private var frameSpikeNominal: FrameDuration?
    private var frameSpikeRequested: FrameDuration?
    private var frameCadence: FrameCadenceTracker?
    private var frameTransitions: [FrameSpikeTransition] = []
    /// Los cambios que se guardan como mucho: 8 h a dos por ventana de 120 s.
    private static let frameSpikeMaxTransitions = 480

    /// IOS-15: lo que dice la grabación de prueba con el volcado activo. Solo se usa
    /// con NV12_DUMP_S puesto; se escribe en Documents/bench al parar.
    private var dumpRunFrames: Int64 = 0
    private var dumpRunDroppedAtStart: Int64 = 0
    private var dumpRunStartNs: UInt64 = 0

    /// Frames en los que no se pudo pintar el código de tiempo. Tiene que ser cero: uno
    /// solo ya es un frame que el servidor no puede emparejar.
    private(set) var timecodeFailures: Int64 = 0

    // MARK: - Ciclo de vida

    func hasUltraWideCamera() -> Bool {
        UltraWideCamera.discover() != nil
    }

    /// Una capa de vista previa sobre esta misma sesión. La compone el GPU: no cuesta
    /// CPU ni toca la salida de vídeo que va al archivo y al stream.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer(session: session)
    }

    func configure(_ settings: CaptureSettings) async throws -> AppliedCameraSettings {
        guard let device = UltraWideCamera.discover() else {
            throw CameraSetupError.noUltraWideCamera
        }

        // El permiso del micro, antes de tocar la sesión: sin él sigue sin micro y el
        // programa va con silencio.
        let conMicro = Self.audioEnabled ? await Self.microphoneAccess() : false

        session.beginConfiguration()
        // `inputPriority` es obligatorio antes de tocar `activeFormat`: con cualquier
        // preset, la sesión reescribe el formato al aplicar la configuración y todo el
        // trabajo de `lockSettings` se pierde en silencio.
        session.sessionPreset = .inputPriority
        // El espacio de color lo fija `lockSettings` (BT.709). Si la sesión lo eligiera
        // sola pondría P3 en unos formatos y no en otros, y las dos cámaras no
        // coincidirían ni entre ellas ni con lo que espera el servidor.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        for input in session.inputs {
            session.removeInput(input)
        }
        micInput = nil
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraSetupError.noUltraWideCamera
        }
        session.addInput(input)
        if Self.audioEnabled {
            micAllowed = conMicro
            setUpAudio()
        }

        if !session.outputs.contains(output) {
            // 4:2:0 biplanar con la luma en el plano 0: es donde `RigTimecode` pinta.
            // Fijarlo, y no dejar el formato por defecto, para que sea el mismo en los
            // dos móviles y en todos los modelos.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        session.commitConfiguration()

        var applied = try UltraWideCamera.lockSettings(on: device, settings: settings)
        if let connection = output.connection(with: .video) {
            let result = UltraWideCamera.configure(connection: connection)
            stabilizationOff = result.stabilizationOff
            intrinsicsAvailable = result.intrinsics
        }

        self.device = device
        self.settings = settings
        self.applied = applied
        thermalMonitor.observe(device: device)
        if pipeline == nil {
            pipeline = RigPipeline(width: applied.width, height: applied.height)
        }

        // Exposición y balance: la cámara mide en automático un momento y después se
        // congela lo medido, trasladado a una obturación sin parpadeo. Fijar un ISO a
        // ciegas, que es lo que hacía esto antes, salía negro en interior y quemado a
        // pleno sol; y congelar el balance antes del primer frame congelaba un color
        // cualquiera.
        startRunning()
        await Self.waitForMetering(on: device)
        try UltraWideCamera.lockExposureAndWhiteBalance(on: device, settings: settings, applied: &applied)
        // Si el maestro ya dijo cómo ve, manda él: lo medido aquí solo valía de reserva.
        if let masterLook {
            try UltraWideCamera.apply(look: masterLook, on: device, applied: &applied)
        }
        self.applied = applied
        if let look = look() { onLookLocked?(look) }
        return applied
    }

    // MARK: - Mismo color en los dos móviles

    /// Cómo ve esta cámara ahora, o `nil` si todavía no ha congelado exposición y balance.
    func look() -> CameraLook? {
        guard let device, let applied, applied.exposureLocked, applied.whiteBalanceLocked else { return nil }
        return CameraLook(
            exposureNs: Int64((applied.exposureSeconds * 1_000_000_000).rounded()),
            iso: applied.iso,
            aperture: device.lensAperture,
            kelvin: applied.whiteBalanceKelvin,
            tint: applied.whiteBalanceTint
        )
    }

    /// Adopta la exposición y el balance del maestro. Si la cámara aún no está lista se
    /// guarda y `configure` lo aplica al terminar de medir.
    func adopt(masterLook look: CameraLook) {
        guard look != masterLook else { return }
        masterLook = look
        guard let device, var applied, applied.exposureLocked else { return }
        do {
            try UltraWideCamera.apply(look: look, on: device, applied: &applied)
            self.applied = applied
            NSLog(
                "[color] ajustes del maestro: 1/%.0f s, ISO %.0f, %.0f K",
                1 / applied.exposureSeconds, Double(applied.iso), Double(applied.whiteBalanceKelvin)
            )
        } catch {
            NSLog("[color] no se pudieron poner los ajustes del maestro: %@", error.localizedDescription)
        }
    }

    /// Sin enlace no hay maestro: la próxima configuración vuelve a lo que mida este móvil.
    func forgetMasterLook() {
        masterLook = nil
    }

    /// Cada cuánto se mira si la cámara terminó de medir, en nanosegundos.
    private static let meteringPollNs: UInt64 = 100_000_000

    /// Sondeos mínimos antes de dar la medida por buena: la sesión tarda en arrancar y
    /// la exposición automática necesita unos frames aunque diga que no está ajustando.
    private static let meteringMinPolls = 7

    /// Sondeos máximos: si en tres segundos no se asienta, se congela lo que haya y la
    /// pantalla enseña los valores para que se vea.
    private static let meteringMaxPolls = 30

    private static func waitForMetering(on device: AVCaptureDevice) async {
        for poll in 1...meteringMaxPolls {
            try? await Task.sleep(nanoseconds: meteringPollNs)
            if poll >= meteringMinPolls, !device.isAdjustingExposure, !device.isAdjustingWhiteBalance {
                return
            }
        }
    }

    /// El permiso del micro: lo pregunta la primera vez y después contesta al instante.
    private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// El audio del programa (IOS-54), dentro de la configuración de la sesión: el
    /// codificador y su vigilante una vez, y el micro si hay permiso. Sin él, o sin
    /// micro, sigue sin audio de verdad y lo dice: el vigilante da el silencio.
    private func setUpAudio() {
        if audio == nil {
            do {
                let captura = try AudioCapture { [weak self] pts in
                    guard let self else { return 0 }
                    let ns = self.hostNs(pts)
                    let offset = self.rigClock?.offsetAt(ns: ns) ?? self.clockOffsetNs
                    return Double(ns + offset) / 1e6
                }
                captura.onFrame = { [weak self] trama in self?.writeAudio(trama) }
                // La 4K se lleva el PCM ya en el eje del AAC: con el del micro tal cual, el
                // escritor apila las muestras y la deriva del micro se acumula.
                captura.onAlignedPcm = { [weak self] pcm, ms in self?.queue.async { self?.appendAudio(pcm, rigMs: ms) } }
                audioOutput.setSampleBufferDelegate(captura, queue: audioQueue)
                audio = captura
                startSilenceWatch()
                observeMicrophoneOwner()
            } catch {
                NSLog("[audio] sin codificador AAC: %@", error.localizedDescription)
                return
            }
        }
        micSuspended = false
        guard micAllowed else {
            NSLog("[audio] sin permiso de micrófono: el programa va con silencio")
            return
        }
        attachMicrophone()
    }

    /// Pone el micro en la sesión; quien llama abre y cierra la configuración.
    @discardableResult
    private func attachMicrophone() -> Bool {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let entrada = try? AVCaptureDeviceInput(device: mic), session.canAddInput(entrada)
        else {
            NSLog("[audio] sin micrófono: el programa va con silencio")
            return false
        }
        session.addInput(entrada)
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
        micInput = entrada
        return true
    }

    /// El vigilante: cada `silenceTickMs`, con la cámara en marcha, el AAC sigue con
    /// silencio si el micro lleva `micStallMs` callado.
    private func startSilenceWatch() {
        let t = DispatchSource.makeTimerSource(queue: audioQueue)
        let periodo = DispatchTimeInterval.milliseconds(AudioConstants.silenceTickMs)
        t.schedule(deadline: .now() + periodo, repeating: periodo)
        t.setEventHandler { [weak self] in
            guard let self, self.session.isRunning, let audio = self.audio else { return }
            audio.keepAlive(nowRigMs: self.rigNowMs())
        }
        t.resume()
        silenceTimer = t
    }

    /// «Ahora» en ms del soporte: el host más el desfase, como los fotogramas.
    private func rigNowMs() -> Double {
        let ahora = CMClockGetTime(CMClockGetHostTimeClock())
        let ns = CMTimeConvertScale(ahora, timescale: 1_000_000_000, method: .default).value
        let offset = rigClock?.offsetAt(ns: ns) ?? clockOffsetNs
        return Double(ns + offset) / 1e6
    }

    /// Quién tiene el micro. Si otro cliente lo toma (una llamada, una alarma), la sesión
    /// ENTERA se para por él: se quita el micro para que siga el vídeo. Vuelve al acabar la
    /// interrupción del audio o la última llamada.
    private func observeMicrophoneOwner() {
        let centro = NotificationCenter.default
        audioObservers.append(centro.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] aviso in
            guard let raw = aviso.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
                  AVCaptureSession.InterruptionReason(rawValue: raw) == .audioDeviceInUseByAnotherClient
            else { return }
            self?.yieldMicrophone()
        })
        audioObservers.append(centro.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] aviso in
            guard let raw = aviso.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self?.reclaimMicrophone()
        })
        callObserver.setDelegate(self, queue: queue)
    }

    /// Otro cliente tiene el micro: fuera de la sesión, y la cámara sigue. El programa y la
    /// pista de audio de la 4K siguen con el silencio del vigilante.
    private func yieldMicrophone() {
        queue.async { [self] in
            guard let micInput else { return }
            session.beginConfiguration()
            session.removeInput(micInput)
            session.commitConfiguration()
            self.micInput = nil
            micSuspended = true
            if !session.isRunning { session.startRunning() }
            NSLog("[audio] otro cliente tomó el micrófono: se quita para que siga el vídeo")
        }
    }

    /// Vuelve el micro si se quitó por otro cliente y no queda ninguna llamada en curso.
    private func reclaimMicrophone() {
        queue.async { [self] in
            guard micSuspended, micAllowed, !callObserver.calls.contains(where: { !$0.hasEnded }) else { return }
            session.beginConfiguration()
            let vuelve = attachMicrophone()
            session.commitConfiguration()
            if vuelve {
                micSuspended = false
                NSLog("[audio] el micrófono vuelve a la sesión")
            }
        }
    }

    /// Las tramas AAC del micro, además del fichero: el banco las mete en el programa.
    var onAacFrame: ((AacFrame) -> Void)?
    var audioFormatDescription: CMAudioFormatDescription? { audio?.formatDescription }

    private func writeAudio(_ trama: AacFrame) {
        onAacFrame?(trama)
        guard Self.audioBenchFile else { return }
        if audioFile == nil {
            let base = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                .appendingPathComponent("bench", isDirectory: true)
            if let base {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let url = base.appendingPathComponent("audio-\(Int(Date().timeIntervalSince1970)).aac")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                audioURL = url
                audioFile = try? FileHandle(forWritingTo: url)
            }
        }
        audioFile?.write(trama.adts)
        audioFrames += 1
        // Un resumen cada ~10 s, para el banco de 10 min.
        if audioFrames % 470 == 0, let url = audioURL, let a = audio {
            let eje = a.syncStats
            let resumen: [String: Any] = ["frames": audioFrames, "buffers_in": a.buffersIn,
                                          "gaps": a.gaps, "failures": a.failures, "last_rig_ms": trama.rigMs,
                                          "silence_ticks": a.silenceTicks, "silence_samples": eje.silenceSamples,
                                          "dropped_samples": eje.droppedSamples, "nudges": eje.nudges,
                                          "reanchors": eje.reanchors]
            if let d = try? JSONSerialization.data(withJSONObject: resumen, options: [.sortedKeys]) {
                try? d.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
        }
    }

    /// El banco de IOS-38 desajusta a propósito la exposición del esclavo en 2^ev: primero
    /// con el ISO y, si llega a su tope (poca luz), el resto con la obturación. Devuelve
    /// lo aplicado de verdad, para el informe.
    func benchExposureBias(ev: Double, done: @escaping ([String: Double]) -> Void) {
        queue.async { [self] in
            guard let device, var applied else { return done(["error": 1]) }
            let f = device.activeFormat
            let factor = pow(2.0, ev)
            let isoAntes = Double(applied.iso)
            let durAntes = CMTimeGetSeconds(device.exposureDuration)
            let iso = min(max(isoAntes * factor, Double(f.minISO)), Double(f.maxISO))
            let resto = factor / (iso / isoAntes)
            let dur = min(max(durAntes * resto, CMTimeGetSeconds(f.minExposureDuration)),
                          CMTimeGetSeconds(f.maxExposureDuration))
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000_000),
                                             iso: Float(iso), completionHandler: nil)
                device.unlockForConfiguration()
                applied.iso = Float(iso)
                applied.exposureSeconds = dur
                self.applied = applied
                done(["iso_before": isoAntes, "iso_after": iso, "exposure_ms_before": durAntes * 1000,
                      "exposure_ms_after": dur * 1000, "ev_applied": log2((iso * dur) / (isoAntes * durAntes))])
            } catch {
                done(["error": 2])
            }
        }
    }

    // MARK: - El spike de la duración de fotograma (2026-10-15)

    /// El banco split trae plan (RIG_SPIKE_FRAME_*): desde ahora se mide la cadencia de la
    /// cámara, también antes de la primera ventana, que es la base.
    func armFrameCadence(fps: Int) {
        queue.async { [self] in
            frameSpikeLock.lock()
            defer { frameSpikeLock.unlock() }
            guard frameCadence == nil else { return }
            let nominal = FrameDuration.nominal(fps: fps)
            frameSpikeNominal = nominal
            frameCadence = FrameCadenceTracker(nominalUs: nominal.microseconds)
            frameSpikeArmed = true
        }
    }

    /// El banco pide una duración de fotograma (nil: la nominal). Como `lockSettings`: con
    /// `lockForConfiguration` y la mínima igual a la máxima (sin cadencia variable), en un
    /// orden que deja siempre mínima ≤ máxima. Lo que el formato activo no admite no se toca
    /// (AVFoundation lanzaría una excepción de ObjC, que tira la app) y queda en el informe.
    /// `benchS` y `rigMs`: cuándo lo pidió el banco, para casarlo con la fase del maestro.
    func benchFrameDuration(_ pedida: FrameDuration?, benchS: Double, rigMs: Int64) {
        queue.async { [self] in
            frameSpikeLock.lock()
            let armado = frameSpikeNominal
            let pedidaAntes = frameSpikeRequested
            frameSpikeLock.unlock()
            guard let nominal = armado else { return }  // sin armar no se mide: no se toca
            let antes = pedidaAntes ?? nominal
            let objetivo = pedida ?? nominal
            var info: [String: Any] = [
                "bench_s": benchS, "rig_ms": rigMs, "requested": objetivo.description,
                "requested_us": objetivo.microseconds, "from_us": antes.microseconds,
            ]
            guard let device else {
                info["rejected"] = "sin cámara"
                return noteFrameTransition(info, effect: nil, requested: nil)
            }
            let cm = CMTime(value: objetivo.value, timescale: objetivo.timescale)
            let formato = device.activeFormat
            let rangos = formato.videoSupportedFrameRateRanges
            info["format_ranges"] = rangos.map { Self.text($0.minFrameDuration) + ".." + Self.text($0.maxFrameDuration) }
            guard rangos.contains(where: {
                CMTimeCompare(cm, $0.minFrameDuration) >= 0 && CMTimeCompare(cm, $0.maxFrameDuration) <= 0
            }) else {
                info["rejected"] = "fuera de las duraciones del formato"
                return noteFrameTransition(info, effect: nil, requested: nil)
            }
            info["exposure_ms_before"] = CMTimeGetSeconds(device.exposureDuration) * Self.msPerS
            info["iso_before"] = Double(device.iso)
            let t0 = RigLink.hostNowNs()
            do {
                try device.lockForConfiguration()
                if CMTimeCompare(cm, device.activeVideoMaxFrameDuration) > 0 {
                    device.activeVideoMaxFrameDuration = cm
                    device.activeVideoMinFrameDuration = cm
                } else {
                    device.activeVideoMinFrameDuration = cm
                    device.activeVideoMaxFrameDuration = cm
                }
                device.unlockForConfiguration()
            } catch {
                info["rejected"] = "lockForConfiguration: \(error.localizedDescription)"
                return noteFrameTransition(info, effect: nil, requested: nil)
            }
            let t1 = RigLink.hostNowNs()
            info["apply_ms"] = Double(t1 - t0) / Self.nsPerMs
            // Lo que dice la cámara que quedó: AVFoundation acepta peticiones que luego no cumple.
            info["readback_min"] = Self.text(device.activeVideoMinFrameDuration)
            info["readback_max"] = Self.text(device.activeVideoMaxFrameDuration)
            info["format_kept"] = device.activeFormat == formato
            info["exposure_mode"] = device.exposureMode.rawValue
            info["session_running"] = session.isRunning
            let efecto = FrameDurationEffect(fromUs: antes.microseconds, toUs: objetivo.microseconds,
                                             requestedAtHostNs: t1)
            noteFrameTransition(info, effect: efecto, requested: .some(pedida))
            NSLog("[spike] duración de fotograma %@ (%.2f µs) a los %.0f s, en %.2f ms", objetivo.description,
                  objetivo.microseconds, benchS, Double(t1 - t0) / Self.nsPerMs)
        }
    }

    /// Anota un cambio pedido; con `requested`, además, lo que pide la cámara desde ahora.
    private func noteFrameTransition(_ info: [String: Any], effect: FrameDurationEffect?,
                                     requested: FrameDuration??) {
        frameSpikeLock.lock()
        defer { frameSpikeLock.unlock() }
        if let requested {
            frameSpikeRequested = requested
            frameCadence?.setRequested(us: requested?.microseconds)
        }
        // Un cambio rechazado se anota con un efecto vacío: nunca se cumple.
        let e = effect ?? FrameDurationEffect(fromUs: 0, toUs: 0, requestedAtHostNs: 0)
        frameTransitions.append(FrameSpikeTransition(info: info, effect: e))
        if frameTransitions.count > Self.frameSpikeMaxTransitions {
            frameTransitions.removeFirst(frameTransitions.count - Self.frameSpikeMaxTransitions)
        }
    }

    /// Cada fotograma con el spike armado: a la cadencia de su cubo de 10 s y, si hay un
    /// cambio pedido reciente, a lo que tarda en notarse. Sin reloj del soporte (el esclavo
    /// al arrancar), solo el sello.
    private func noteFrameCadence(hostNs: Int64, rigNs: Int64) {
        let conReloj = recordingClockState() != .waiting
        frameSpikeLock.lock()
        defer { frameSpikeLock.unlock() }
        guard let c = frameCadence,
              let periodo = c.record(frameHostNs: hostNs, rigMs: conReloj ? rigNs / Self.nsPerMsInt : nil,
                                     recordedTotal: recordedFrames),
              let i = frameTransitions.indices.last,
              !frameTransitions[i].effect.isComplete,
              frameTransitions[i].info["rejected"] == nil,
              hostNs > frameTransitions[i].effect.requestedAtHostNs
        else { return }
        frameTransitions[i].effect.observe(periodUs: periodo, frameHostNs: hostNs)
        if frameTransitions[i].effect.isComplete, let device {
            // ¿Tocó la exposición? Lo que hay 3 s después del cambio.
            frameTransitions[i].info["exposure_ms_after_3s"] = CMTimeGetSeconds(device.exposureDuration) * Self.msPerS
            frameTransitions[i].info["iso_after_3s"] = Double(device.iso)
        }
    }

    /// Lo medido, para el informe del banco: la cadencia cada 10 s del reloj del soporte y
    /// cada cambio pedido con lo que tardó en notarse. [:] sin spike.
    func frameSpikeReport() -> [String: Any] {
        frameSpikeLock.lock()
        defer { frameSpikeLock.unlock() }
        guard let c = frameCadence, let nominal = frameSpikeNominal else { return [:] }
        func r(_ x: Double) -> Double { (x * Self.reportScale).rounded() / Self.reportScale }
        return [
            "nominal": nominal.description,
            "nominal_us": nominal.microseconds,
            "cadence_columns": ["start_rig_ms", "intervals", "mean_us", "p50_us", "p99_us", "gaps", "did_drop",
                                "frames_4k", "requested_us"],
            "cadence_by_10s": c.buckets.map { b -> [Any] in
                [b.startRigMs, b.intervals, r(b.meanUs), r(b.p50Us), r(b.p99Us), b.gaps, b.drops, b.recorded,
                 r(b.requestedUs)]
            },
            "transitions": frameTransitions.map { t -> [String: Any] in
                var d = t.info
                d["frames_to_effect"] = t.effect.framesToEffect ?? -1
                d["ms_to_effect"] = t.effect.msToEffect.map(r) ?? -1
                d["periods_us"] = t.effect.periodsUs.map(r)
                return d
            },
        ]
    }

    /// Una duración de CMTime como «valor/escala», sin redondear.
    private static func text(_ t: CMTime) -> String { "\(t.value)/\(t.timescale)" }
    private static let msPerS = 1000.0
    private static let nsPerMs = 1e6
    private static let nsPerMsInt: Int64 = 1_000_000
    /// Dos decimales en el informe: centésimas de µs y de ms.
    private static let reportScale = 100.0

    /// El banco de IOS-84 para y reanuda la cámara a propósito (como una interrupción).
    func setCameraRunningForBench(_ on: Bool) {
        queue.async { [self] in
            if on { if !session.isRunning { session.startRunning() } } else { session.stopRunning() }
        }
    }

    func startRunning() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// Reabre la sesión para volver a sortear la fase de exposición (TASK A4).
    ///
    /// Parar y arrancar es lo único que mueve la fase: no hay API para fijarla, así que
    /// se vuelve a tirar los dados.
    func restartForPhase() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.recentPts.removeAll()
            self.session.startRunning()
        }
    }

    func setClockOffsetNs(_ offsetNs: Int64) {
        queue.async { [weak self] in
            self?.clockOffsetNs = offsetNs
        }
    }

    /// Este móvil pasa a ser (o deja de ser) la referencia del reloj del soporte: el rol
    /// que negoció el enlace. Un esclavo no abre la 4K hasta tener estimación.
    func setClockReference(_ on: Bool) {
        queue.async { [weak self] in
            self?.isClockReference = on
        }
    }

    /// Qué sabe la cámara del reloj del soporte ahora mismo, en la cola de captura.
    private func recordingClockState() -> RecordingClockState {
        guard let rigClock else { return .unlinked }
        if isClockReference { return .reference }
        return rigClock.estimate == nil ? .waiting : .estimated
    }

    /// Copia la puerta del reloj para quien la lee fuera de la cola de captura.
    private func publishClockGate() {
        recordingLock.lock()
        clockGateSnapshot = clockGate
        recordingLock.unlock()
    }

    /// Los contadores de la puerta del reloj, para el informe del banco.
    func recordingClockReport() -> [String: Any] {
        let g = recordingClock
        return [
            "clock_wait_frames": g.framesWaitingForClock,
            "clock_jump_segments": g.segmentsFromClockJump,
            "sessions_without_clock": g.sessionsWithoutClock,
            "out_of_order_frames": g.framesOutOfOrder,
            "audio_dropped_on_jump": g.audioDroppedOnJump,
            "audio_not_ready": recordingAudioNotReady,
        ]
    }

    func recentFramePtsNs() -> [Int64] {
        queue.sync { recentPts }
    }

    // MARK: - Grabación

    /// `reserveBytes`: lo que tiene que quedar libre; el banco de SPK-04 pide solo lo de su
    /// pasada (RecordingPolicy.benchReserveBytes).
    func startRecording(directory: String,
                        reserveBytes: Int64 = RecordingPolicy.phoneDiskReserveBytes) throws -> String {
        // IOS-57: la 4K no arranca sin la reserva de disco, y la emisión sigue sin ella
        // (devuelve "" y Dart lo avisa). Las grabaciones anteriores ya no se borran al
        // empezar: las borra la ingesta (ML-08) al confirmarlas, o el operador a mano.
        let libre = Self.freeDiskBytes()
        guard RecordingPolicy.allowsLocalRecording(freeBytes: libre, reserveBytes: reserveBytes) else {
            NSLog("[grabacion] sin 4K: quedan %lld bytes libres, menos que la reserva", libre)
            recordingWanted = false
            return ""
        }
        recordingWanted = true
        recordingStoppedForDisk = false
        recordingDirectory = directory
        // Una grabación nueva cuenta desde cero lo que el reloj del soporte le hizo esperar
        // o cortar. En la cola, antes de que se instale su primer segmento.
        queue.async { [self] in
            clockGate = RecordingClockGate()
            publishClockGate()
        }
        if nv12Dumper != nil {
            queue.async { [self] in
                dumpRunFrames = 0
                dumpRunDroppedAtStart = droppedFrames
                dumpRunStartNs = DispatchTime.now().uptimeNanoseconds
            }
        }
        return try openSegment(number: 1)
    }

    /// Borra los `.mov` de la carpeta de grabaciones, a mano. No toca nada más: ahí solo
    /// escribe esta app.
    static func removeRecordings(in directory: String) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return }
        var borrados = 0
        for name in names where name.hasSuffix(".mov") {
            let path = (directory as NSString).appendingPathComponent(name)
            if (try? manager.removeItem(atPath: path)) != nil { borrados += 1 }
        }
        if borrados > 0 {
            NSLog("[grabacion] %d grabaciones anteriores borradas", borrados)
        }
    }

    /// Un segmento de la 4K listo para recibir su primer fotograma.
    private struct Segment {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput?
        let path: String
    }

    /// Abre el segmento `number` desde fuera de la cola de captura: al empezar a grabar o
    /// al volver de un corte. Se instala en la cola, cerrando antes el que hubiera.
    private func openSegment(number: Int) throws -> String {
        let nuevo = try makeSegment(number: number)
        queue.async { [weak self] in
            guard let self else { return }
            // Si había una grabación abierta (dos toques seguidos), se cierra antes.
            self.closeWriter()
            self.install(nuevo)
            // Un segmento abierto desde fuera empieza sin sesión: el primer fotograma
            // con reloj la abre.
            self.clockGate.segmentOpened()
        }
        return nuevo.path
    }

    /// El reloj del soporte saltó a mitad de segmento (RecordingClockGate): se cierra con
    /// lo que tiene y se abre el siguiente aquí mismo, en la cola de captura, para que el
    /// fotograma que saltó ya vaya en él. Devuelve si quedó abierto.
    private func rollSegmentForClockJump() -> Bool {
        closeWriter()
        let numero = recordingSegment + 1
        do {
            install(try makeSegment(number: numero))
            NSLog("[grabacion] el reloj del soporte saltó: segmento %d", numero)
            return true
        } catch {
            NSLog("[grabacion] no se pudo abrir el segmento %d: %@", numero, error.localizedDescription)
            return false
        }
    }

    private func install(_ segment: Segment) {
        writer = segment.writer
        writerInput = segment.video
        audioWriterInput = segment.audio
        writerStarted = false
    }

    /// El archivo del segmento `number`. Un fichero por arranque, con el lado en el
    /// nombre: en el servidor hay que poder saber cuál es cuál sin abrirlos. Tras un
    /// corte, el siguiente segmento lleva su número al final.
    private func makeSegment(number: Int) throws -> Segment {
        guard let settings, let applied else {
            throw CameraSetupError.noUltraWideCamera
        }
        let name = Self.segmentName(
            role: settings.role,
            epochSeconds: Int(Date().timeIntervalSince1970),
            segment: number
        )
        let url = URL(fileURLWithPath: recordingDirectory).appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 2026-10-14: en fragmentos, para que una app que muere a mitad (batería, jetsam,
        // disco lleno) no deje 30 GB sin índice que no abre nadie (RecordingPolicy).
        writer.movieFragmentInterval = CMTime(seconds: RecordingPolicy.movieFragmentIntervalS,
                                              preferredTimescale: Self.fragmentTimescale)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: applied.width,
                AVVideoHeightKey: applied.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: RecordingPolicy.localBitrateBps,
                    AVVideoExpectedSourceFrameRateKey: Int(settings.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(settings.fps) * 2,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        }
        var audioInput: AVAssetWriterInput?
        if audio != nil, micAllowed {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioConstants.sampleRate,
                AVNumberOfChannelsKey: AudioConstants.programChannels,
                AVEncoderBitRateKey: AudioConstants.aacBitrateBps,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            }
        }
        recordingLock.lock()
        segmentNumber = number
        segmentFile = url.path
        recordingLock.unlock()
        return Segment(writer: writer, video: input, audio: audioInput, path: url.path)
    }

    func stopRecording() {
        recordingWanted = false
        queue.async { [weak self] in
            self?.closeWriter()
            self?.writeDumpRunReport()
        }
    }

    /// La escala de los instantes del intervalo de fragmentos, en tics por segundo.
    private static let fragmentTimescale: CMTimeScale = 600

    /// La 4K cerrada por quedarse sin disco (RecordingPolicy.diskFloorBytes), para la
    /// pantalla y el informe.
    private(set) var recordingStoppedForDisk = false

    /// 2026-10-14: con menos del suelo libre, la 4K se cierra (entera) para que la copia del
    /// programa, el N0 y los informes no se queden sin sitio a la vez. Lo mira el estado,
    /// que Dart pide una vez por segundo.
    private func enforceDiskFloor(freeBytes: Int64) {
        guard recordingWanted, RecordingPolicy.mustStopForDisk(freeBytes: freeBytes) else { return }
        NSLog("[grabacion] la 4K se cierra: quedan %lld bytes libres", freeBytes)
        recordingStoppedForDisk = true
        stopRecording()
    }

    /// IOS-15: el informe de la grabación de prueba con el volcado: fotogramas que
    /// entraron al archivo, fps real, didDrop y descartes del escritor, fallos del
    /// código de tiempo y volcados escritos. Solo en modo banco (NV12_DUMP_S).
    private func writeDumpRunReport() {
        guard let dumper = nv12Dumper, dumpRunStartNs > 0 else { return }
        dumper.drain()
        let duracion = Double(DispatchTime.now().uptimeNanoseconds - dumpRunStartNs) / 1e9
        let informe: [String: Any] = [
            "name": "nv12-dump-run",
            "duration_s": duracion,
            "frames_recorded": dumpRunFrames,
            "fps": duracion > 0 ? Double(dumpRunFrames) / duracion : 0,
            "dropped_frames": droppedFrames - dumpRunDroppedAtStart,
            "timecode_failures": timecodeFailures,
            "nv12_written": dumper.written,
            "nv12_failures": dumper.failures,
            "recording_file": recordingFile ?? "",
        ]
        guard let documentos = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let datos = try? JSONSerialization.data(withJSONObject: informe, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let carpeta = documentos.appendingPathComponent("bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let epoch = Int(Date().timeIntervalSince1970)
        try? datos.write(to: carpeta.appendingPathComponent("nv12-dump-run-\(epoch).json"))
        dumpRunStartNs = 0
    }

    static func segmentName(role: CameraRole, epochSeconds: Int, segment: Int) -> String {
        let side = role == .left ? "left" : "right"
        return segment <= 1 ? "\(side)-\(epochSeconds).mov" : "\(side)-\(epochSeconds)-\(segment).mov"
    }

    // MARK: - Cortes

    /// La cámara se interrumpió (la app pasó atrás, otra app la tomó, el sistema la
    /// recortó por calor). Se cierra el segmento ahora, con el archivo entero y
    /// reproducible, en vez de dejarlo abierto: si iOS mata la app mientras dure el
    /// corte, un archivo abierto no se puede leer.
    func interruptionBegan() {
        queue.async { [weak self] in
            self?.closeWriter()
        }
    }

    /// Volvió la cámara. Si se estaba grabando, se sigue en un segmento nuevo sin que
    /// nadie pulse nada: en la cancha nadie está mirando el móvil.
    func interruptionEnded() {
        guard recordingWanted else { return }
        let numero = recordingSegment + 1
        do {
            _ = try openSegment(number: numero)
        } catch {
            NSLog("[capture] no se pudo abrir el segmento %d: %@", numero, error.localizedDescription)
        }
    }

    /// Error de ejecución de la sesión (por ejemplo, los servicios de vídeo del sistema
    /// se reiniciaron). Lo único que lo arregla es volver a arrancar.
    func runtimeErrorOccurred() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    // MARK: - Calor

    /// Fracción del bitrate de emisión por estado térmico. Escalones fijos, no un
    /// control continuo: dos móviles con controles continuos se pelean por Starlink
    /// (ADR 0012, decisión 7). La grabación local no se toca: el archivo es la verdad.
    static func bitrateFraction(for state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal, .fair: return 1.0
        case .serious: return 2.0 / 3.0
        case .critical: return 0.4
        @unknown default: return 0.4
        }
    }

    func thermalStateChanged() {
        guard let settings else { return }
        let fraction = Self.bitrateFraction(for: ProcessInfo.processInfo.thermalState)
        publisher.setBitRate(Int(Double(settings.bitrateBps) * fraction))
    }

    /// Cierra el escritor, en la cola de captura.
    ///
    /// Solo se termina un archivo que empezó. `markAsFinished` sobre un escritor que
    /// nunca recibió un frame no devuelve error: tira la app entera, y es exactamente
    /// lo que pasa si PARAR llega antes que el primer frame.
    private func closeWriter() {
        guard let writer else { return }
        if writer.status == .writing {
            if writerStarted {
                writerInput?.markAsFinished()
                audioWriterInput?.markAsFinished()
                writer.finishWriting {}
            } else {
                writer.cancelWriting()
            }
        }
        self.writer = nil
        writerInput = nil
        audioWriterInput = nil
        writerStarted = false
    }

    /// Trozos de PCM que la pista de audio de la 4K no aceptó a tiempo (se tiran: nunca se
    /// encola). Cada uno adelanta lo que sigue, porque el escritor apila las muestras.
    private(set) var recordingAudioNotReady: Int64 = 0

    /// El PCM del eje del AAC a la pista de audio de la 4K (estéreo, como el programa), en
    /// la cola de captura. Va seguido y en el reloj del soporte: el silencio de los cortes
    /// del micro incluido. Antes del primer fotograma no hay sesión abierta y se tira; si
    /// la pista va por detrás, también: nunca se encola. Y si el desfase ya no es el del
    /// segmento (el reloj saltó y el vídeo aún no cortó), también: alargaría el fichero
    /// hasta el dominio nuevo.
    private func appendAudio(_ pcm: AVAudioPCMBuffer, rigMs: Double) {
        guard writerStarted, let writer, writer.status == .writing, let input = audioWriterInput else { return }
        guard input.isReadyForMoreMediaData else {
            recordingAudioNotReady += 1
            return
        }
        let ahora = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000,
                                       method: .default).value
        guard clockGate.audio(offsetNs: rigClock?.offsetAt(ns: ahora) ?? clockOffsetNs) else {
            publishClockGate()
            return
        }
        if let muestra = AudioCapture.sampleBuffer(pcm, ptsNs: Int64((rigMs * 1_000_000).rounded())) {
            input.append(muestra)
        }
    }

    /// Empieza a emitir al servidor. Independiente de la grabación: si esto falla, el
    /// archivo sigue (ADR 0012, decisión 5).
    func startStreaming(to url: URL) throws {
        guard let settings, let applied else {
            throw CameraSetupError.noUltraWideCamera
        }
        publisher.start(url: url, settings: settings, applied: applied)
    }

    func stopStreaming() {
        publisher.stop()
    }

    /// Para la grabación y la emisión, y **deja la cámara viva**.
    ///
    /// Apagarla aquí era lo que obligaba a cerrar la app para volver a grabar: tras PARAR
    /// la sesión de captura quedaba parada, `startRecording` solo abre el fichero, y el
    /// siguiente GRABAR se quedaba esperando unos frames que ya no llegaban (visto en los
    /// dos móviles el 27-09-2026). Además dejaba la vista previa congelada.
    func stop() {
        publisher.stop()
        stopRecording()
    }

    /// Apaga la cámara. Al salir de la pantalla de captura, no al parar de grabar.
    func releaseCamera() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Estado

    func status() -> CaptureStatus {
        let applied = self.applied
        let reloj = recordingClock
        let libre = Self.freeDiskBytes()
        enforceDiskFloor(freeBytes: libre)
        return CaptureStatus(
            running: session.isRunning,
            width: Int64(applied?.width ?? 0),
            height: Int64(applied?.height ?? 0),
            actualFps: applied?.actualFps ?? 0,
            stabilizationDisabled: stabilizationOff,
            exposureLocked: applied?.exposureLocked ?? false,
            exposureSeconds: applied?.exposureSeconds ?? 0,
            iso: Int64((applied?.iso ?? 0).rounded()),
            whiteBalanceLocked: applied?.whiteBalanceLocked ?? false,
            whiteBalanceKelvin: Int64((applied?.whiteBalanceKelvin ?? 0).rounded()),
            focusLocked: applied?.focusLocked ?? false,
            intrinsicsAvailable: intrinsicsAvailable,
            thermalState: Self.thermalState(),
            pressure: Self.pressure(thermalMonitor.pressure),
            ladderLevel: Int64((programLadderLevel?() ?? stepLadder()).rawValue),
            batteryLevel: Double(UIDevice.current.batteryLevel),
            freeDiskBytes: libre,
            droppedFrames: droppedFrames,
            timecodeFailures: timecodeFailures,
            recordingFile: recordingFile,
            recordingSegment: Int64(recordingSegment),
            recordingClockWaitFrames: reloj.framesWaitingForClock,
            recordingClockJumpSegments: reloj.segmentsFromClockJump,
            streamState: Self.streamState(publisher.state),
            streamDetail: Self.streamDetail(publisher.state),
            streamDroppedFrames: publisher.droppedFrames,
            streamBitrateBps: Int64(publisher.currentBitRate)
        )
    }

    private static func streamState(_ state: StreamPublisher.State) -> StreamState {
        switch state {
        case .off: return .off
        case .connecting: return .connecting
        case .streaming: return .streaming
        case .reconnecting: return .reconnecting
        case .failed: return .failed
        }
    }

    private static func streamDetail(_ state: StreamPublisher.State) -> String {
        switch state {
        case let .reconnecting(detail), let .failed(detail): return detail
        default: return ""
        }
    }

    /// Lo que piden los sensores ahora, sin histéresis: el objetivo de la escalera de la
    /// pasada del programa. Se llama desde su cola: la presión va tras el candado del monitor.
    func ladderSensorTarget() -> LadderLevel {
        DegradationLadder.target(
            thermal: ThermalMonitor.level(from: ProcessInfo.processInfo.thermalState),
            pressure: thermalMonitor.pressure,
            charging: Self.charging()
        )
    }

    private static func charging() -> Bool {
        UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    /// Avanza la escalera con el tiempo real transcurrido desde la última foto.
    /// El estado se pide a 1 Hz desde Dart, así que este es su tic.
    private func stepLadder() -> LadderLevel {
        let ahora = CMClockGetTime(CMClockGetHostTimeClock())
        let dt = max(0, CMTimeGetSeconds(CMTimeSubtract(ahora, ladderSteppedAt)))
        ladderSteppedAt = ahora
        return ladder.step(
            thermal: ThermalMonitor.level(from: ProcessInfo.processInfo.thermalState),
            pressure: thermalMonitor.pressure,
            charging: Self.charging(),
            dtS: dt
        )
    }

    private static func pressure(_ level: PressureLevel) -> SystemPressure {
        switch level {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        case .shutdown: return .shutdown
        }
    }

    private static func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

// MARK: - Frames

extension CaptureEngine {
    /// Un PTS de la cámara o del micro en el reloj del host, en ns.
    ///
    /// AVFoundation sella en `session.synchronizationClock`, y con el micro dentro de la
    /// sesión ese reloj es el del dispositivo de audio, no el del host: deriva decenas de
    /// ppm. El tic del programa, el enlace y el reloj del soporte van en el del host, así
    /// que sin convertir el fotograma propio del maestro se iba alejando del instante que
    /// se le pedía (medido el 2026-10-07: sin él en el 79 % del programa a los 90 min).
    func hostNs(_ pts: CMTime) -> Int64 {
        let host = CMClockGetHostTimeClock()
        let enHost = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: host) } ?? pts
        return CMTimeConvertScale(enHost, timescale: 1_000_000_000, method: .default).value
    }

    /// Anota, una vez por minuto, cuánto se ha separado el reloj de la sesión del del
    /// host desde el primer fotograma, en ms. El banco lo saca en su informe.
    func noteClockSkew(pts: CMTime, hostNs ns: Int64) {
        let crudo = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        let diferencia = ns - crudo
        guard let inicio = clockSkewStart else {
            clockSkewStart = (ns, diferencia)
            return
        }
        let minutos = Int((ns - inicio.atNs) / Self.nsPerMinute)
        if minutos >= clockSkewByMinuteMs.count {
            clockSkewByMinuteMs.append(Double(diferencia - inicio.skewNs) / 1e6)
        }
    }
}

extension CaptureEngine: CXCallObserverDelegate {
    /// Al acabar una llamada, el micro vuelve si se quitó por ella (y no queda otra).
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded { reclaimMicrophone() }
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // IOS-13: con el enlace sobre Network el desfase sale del reloj nativo, por
        // fotograma y extrapolando la deriva, sin pasar por Pigeon. Con el Multipeer
        // de hoy sigue llegando de Dart por setClockOffsetNs.
        let originalNs = hostNs(original)
        noteClockSkew(pts: original, hostNs: originalNs)
        let offsetNs = rigClock?.offsetAt(ns: originalNs) ?? clockOffsetNs
        let rigNs = originalNs + offsetNs
        let rigTime = CMTime(value: rigNs, timescale: 1_000_000_000)
        if frameSpikeArmed { noteFrameCadence(hostNs: originalNs, rigNs: rigNs) }

        recentPts.append(rigNs)
        if recentPts.count > recentPtsCapacity {
            recentPts.removeFirst(recentPts.count - recentPtsCapacity)
        }

        // El tiempo del soporte, pintado en la esquina del frame (enmienda B1a): es lo
        // que el servidor lee para emparejar, y sobrevive a cualquier relé. Va en todos
        // los frames, se grabe o no, para que archivo y stream lo lleven igual.
        let rigMs = UInt64(max(0, rigNs / 1_000_000))
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
           RigTimecode.write(valueMs: rigMs, into: pixels) {
            // pintado
        } else {
            timecodeFailures += 1
        }

        // IOS-09: el pipeline copia el fotograma a su anillo sin bloquear y sin retener
        // más de un búfer de la cámara. La grabación y la emisión no pasan por él.
        pipeline?.ingest(sampleBuffer, rigNs: rigNs)

        // IOS-15: el volcado NV12 en modo banco. Copia aquí (el búfer es nuestro ahora
        // mismo) y escribe en su cola; corre una vez cada N segundos, no por fotograma.
        if let dumper = nv12Dumper, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            dumper.maybeDump(pixels, rigMs: rigMs)
        }

        // Al stream va el mismo buffer ya pintado. No bloquea: si el codificador va por
        // detrás, el frame se descarta y se cuenta.
        publisher.append(sampleBuffer)

        guard writer != nil else { return }

        // La 4K, solo con un reloj del soporte que valga y sin saltos dentro de un
        // fichero (RecordingClockGate): el esclavo no abre la sesión hasta tener
        // estimación, y un salto del desfase cierra el segmento y abre otro.
        let decision = clockGate.video(hostNs: originalNs, offsetNs: offsetNs, clock: recordingClockState())
        switch decision {
        case .append:
            appendToRecording(sampleBuffer, at: rigTime, startsSession: false)
        case .startSession:
            publishClockGate()
            appendToRecording(sampleBuffer, at: rigTime, startsSession: true)
        case let .rollSegment(empieza):
            publishClockGate()
            guard rollSegmentForClockJump(), empieza else { return }
            appendToRecording(sampleBuffer, at: rigTime, startsSession: true)
        case .waitForClock, .outOfOrder:
            publishClockGate()
        }
    }

    /// Mete un fotograma ya sellado en la 4K; con `startsSession`, abre antes la sesión
    /// del escritor en su sello.
    private func appendToRecording(_ sampleBuffer: CMSampleBuffer, at rigTime: CMTime, startsSession: Bool) {
        guard let writer, let input = writerInput else { return }
        if startsSession, !writerStarted {
            guard writer.startWriting() else {
                // No se pudo abrir el archivo (disco, permisos): se suelta el escritor
                // para no seguir intentándolo frame a frame, y queda en el log.
                NSLog("[capture] no se pudo empezar a grabar: %@", writer.error?.localizedDescription ?? "?")
                self.writer = nil
                writerInput = nil
                return
            }
            writer.startSession(atSourceTime: rigTime)
            writerStarted = true
        }
        guard writerStarted, writer.status == .writing else {
            droppedFrames += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            // Nunca se encola: si el escritor va por detrás, el frame se pierde y se
            // cuenta. Es la misma regla que en el servidor (CLAUDE.md §2).
            droppedFrames += 1
            return
        }
        if let retimed = Self.retimed(sampleBuffer, to: rigTime), input.append(retimed) {
            dumpRunFrames += 1
            recordedFrames += 1
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrames += 1
        if frameSpikeArmed {
            frameSpikeLock.lock()
            frameCadence?.recordDrop()
            frameSpikeLock.unlock()
        }
        let motivo = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String
        if motivo == String(kCMSampleBufferDroppedFrameReason_OutOfBuffers) {
            cameraDropsOutOfBuffers += 1
        } else if motivo == String(kCMSampleBufferDroppedFrameReason_FrameWasLate) {
            cameraDropsLate += 1
        } else {
            cameraDropsOther += 1
        }
    }

    /// Copia el buffer cambiándole el sello al tiempo del soporte.
    ///
    /// Se reescribe el PTS y no se corrige después en el servidor porque el servidor no
    /// tiene forma de saber el desfase: el único sitio donde se conoce es el móvil que
    /// lo midió contra el otro.
    private static func retimed(_ buffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
