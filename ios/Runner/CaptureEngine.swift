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

    // IOS-06: los sensores y la escalera. Hoy observan y se enseñan en el estado; las
    // acciones gobernarán el pipeline cuando IOS-25/IOS-44/IOS-50 las consuman.
    private let thermalMonitor = ThermalMonitor()
    private var ladder = DegradationLadder()

    // IOS-09: el enganche del pipeline. Copia cada fotograma al anillo propio sin
    // retener más de un búfer de la cámara; sus consumidores llegan con IOS-23+.
    private var pipeline: RigPipeline?

    // IOS-54: el micrófono, solo con RIG_AUDIO=1 hasta que se acepte el permiso en los
    // dos móviles. Las tramas AAC van a Documents/bench/audio-<t>.aac, con su informe.
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "io.footballai.capture.audio", qos: .userInitiated)
    private var audio: AudioCapture?
    private var audioFile: FileHandle?
    private var audioURL: URL?
    private var audioFrames = 0
    static var audioEnabled: Bool { ProcessInfo.processInfo.environment["RIG_AUDIO"] == "1" }

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
    private(set) var recordingSegment = 0
    private(set) var recordingFile = ""

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
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraSetupError.noUltraWideCamera
        }
        session.addInput(input)
        if Self.audioEnabled {
            addMicrophone()
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

    /// El micro en la misma sesión (IOS-54). Si falla, sigue sin audio y lo dice.
    private func addMicrophone() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let entrada = try? AVCaptureDeviceInput(device: mic), session.canAddInput(entrada)
        else {
            NSLog("[audio] sin micrófono: sigue sin audio")
            return
        }
        session.addInput(entrada)
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
        let captura = AudioCapture { [weak self] pts in
            let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
            let offset = self?.rigClock?.offsetAt(ns: ns) ?? self?.clockOffsetNs ?? 0
            return Double(ns + offset) / 1e6
        }
        captura.onFrame = { [weak self] trama in self?.writeAudio(trama) }
        captura.onSampleBuffer = { [weak self] pcm in self?.queue.async { self?.appendAudio(pcm) } }
        audioOutput.setSampleBufferDelegate(captura, queue: audioQueue)
        audio = captura
    }

    /// Las tramas AAC del micro, además del fichero: el banco las mete en el programa.
    var onAacFrame: ((AacFrame) -> Void)?
    var audioFormatDescription: CMAudioFormatDescription? { audio?.formatDescription }

    private func writeAudio(_ trama: AacFrame) {
        onAacFrame?(trama)
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
            let resumen: [String: Any] = ["frames": audioFrames, "buffers_in": a.buffersIn,
                                          "gaps": a.gaps, "failures": a.failures, "last_rig_ms": trama.rigMs]
            if let d = try? JSONSerialization.data(withJSONObject: resumen, options: [.sortedKeys]) {
                try? d.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
        }
    }

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

    func recentFramePtsNs() -> [Int64] {
        queue.sync { recentPts }
    }

    // MARK: - Grabación

    func startRecording(directory: String) throws -> String {
        // IOS-57: la 4K no arranca sin la reserva de disco, y la emisión sigue sin ella
        // (devuelve "" y Dart lo avisa). Las grabaciones anteriores ya no se borran al
        // empezar: las borra la ingesta (ML-08) al confirmarlas, o el operador a mano.
        let libre = Self.freeDiskBytes()
        guard RecordingPolicy.allowsLocalRecording(freeBytes: libre) else {
            NSLog("[grabacion] sin 4K: quedan %lld bytes libres, menos que la reserva", libre)
            recordingWanted = false
            return ""
        }
        recordingWanted = true
        recordingDirectory = directory
        recordingSegment = 1
        if nv12Dumper != nil {
            queue.async { [self] in
                dumpRunFrames = 0
                dumpRunDroppedAtStart = droppedFrames
                dumpRunStartNs = DispatchTime.now().uptimeNanoseconds
            }
        }
        return try openSegment()
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

    /// Abre el archivo del segmento actual. Un fichero por arranque, con el lado en el
    /// nombre: en el servidor hay que poder saber cuál es cuál sin abrirlos. Tras un
    /// corte, el siguiente segmento lleva su número al final.
    private func openSegment() throws -> String {
        guard let settings, let applied else {
            throw CameraSetupError.noUltraWideCamera
        }
        let name = Self.segmentName(
            role: settings.role,
            epochSeconds: Int(Date().timeIntervalSince1970),
            segment: recordingSegment
        )
        let url = URL(fileURLWithPath: recordingDirectory).appendingPathComponent(name)
        recordingFile = url.path

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: applied.width,
                AVVideoHeightKey: applied.height,
                AVVideoCompressionPropertiesKey: [
                    // 45 Mbit/s: el archivo local no comparte el limite de Starlink, y
                    // es de donde sale el partido bueno si la emision se degrada.
                    AVVideoAverageBitRateKey: 45_000_000,
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
        if audio != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioConstants.sampleRate,
                AVNumberOfChannelsKey: Self.recordingAudioChannels,
                AVEncoderBitRateKey: AudioConstants.aacBitrateBps,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            // Si había una grabación abierta (dos toques seguidos), se cierra antes.
            self.closeWriter()
            self.writer = writer
            self.writerInput = input
            self.audioWriterInput = audioInput
            self.writerStarted = false
        }
        return url.path
    }

    func stopRecording() {
        recordingWanted = false
        queue.async { [weak self] in
            self?.closeWriter()
            self?.writeDumpRunReport()
        }
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
        recordingSegment += 1
        do {
            _ = try openSegment()
        } catch {
            NSLog("[capture] no se pudo abrir el segmento %d: %@", recordingSegment, error.localizedDescription)
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

    /// Canales de la pista de audio de la 4K: el micro del iPhone es mono.
    private static let recordingAudioChannels = 1

    /// El PCM del micro a la pista de audio de la 4K, en la cola de captura y con el
    /// mismo desfase al soporte que el vídeo. Antes del primer fotograma no hay sesión
    /// abierta y se tira; si la pista va por detrás, también: nunca se encola.
    private func appendAudio(_ pcm: CMSampleBuffer) {
        guard writerStarted, let writer, writer.status == .writing, let input = audioWriterInput,
              input.isReadyForMoreMediaData
        else { return }
        let ns = CMTimeConvertScale(
            CMSampleBufferGetPresentationTimeStamp(pcm), timescale: 1_000_000_000, method: .default
        ).value
        let desfase = rigClock?.offsetAt(ns: ns) ?? clockOffsetNs
        if let copia = SampleRetime.shifted(pcm, byNs: desfase) {
            input.append(copia)
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
            ladderLevel: Int64(stepLadder().rawValue),
            batteryLevel: Double(UIDevice.current.batteryLevel),
            freeDiskBytes: Self.freeDiskBytes(),
            droppedFrames: droppedFrames,
            timecodeFailures: timecodeFailures,
            recordingFile: recordingFile,
            recordingSegment: Int64(recordingSegment),
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

    /// Avanza la escalera con el tiempo real transcurrido desde la última foto.
    /// El estado se pide a 1 Hz desde Dart, así que este es su tic.
    private func stepLadder() -> LadderLevel {
        let ahora = CMClockGetTime(CMClockGetHostTimeClock())
        let dt = max(0, CMTimeGetSeconds(CMTimeSubtract(ahora, ladderSteppedAt)))
        ladderSteppedAt = ahora
        let cargando = UIDevice.current.batteryState == .charging
            || UIDevice.current.batteryState == .full
        return ladder.step(
            thermal: ThermalMonitor.level(from: ProcessInfo.processInfo.thermalState),
            pressure: thermalMonitor.pressure,
            charging: cargando,
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

    private static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

// MARK: - Frames

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
        let originalNs = CMTimeConvertScale(original, timescale: 1_000_000_000, method: .default).value
        let offsetNs = rigClock?.offsetAt(ns: originalNs) ?? clockOffsetNs
        let rigTime = CMTimeAdd(original, CMTime(value: offsetNs, timescale: 1_000_000_000))

        let rigNs = Int64(CMTimeGetSeconds(rigTime) * 1_000_000_000)
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

        guard let writer, let input = writerInput else { return }

        if !writerStarted {
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
        guard writer.status == .writing else {
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
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrames += 1
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
