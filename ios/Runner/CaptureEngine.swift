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
//
// NO COMPILADO. Se escribió en Windows: no ha pasado por Xcode ni por un dispositivo.

import AVFoundation
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

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerStarted = false

    /// Desfase al tiempo del soporte, en nanosegundos. Lo fija Dart.
    private var clockOffsetNs: Int64 = 0

    /// Últimos PTS entregados, en tiempo del soporte. Es lo que Dart resta contra los
    /// del otro móvil para medir la fase de exposición (TASK A4).
    private var recentPts: [Int64] = []
    private let recentPtsCapacity = 30

    private(set) var droppedFrames: Int64 = 0

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

        // Exposición y balance: la cámara mide en automático un momento y después se
        // congela lo medido, trasladado a una obturación sin parpadeo. Fijar un ISO a
        // ciegas, que es lo que hacía esto antes, salía negro en interior y quemado a
        // pleno sol; y congelar el balance antes del primer frame congelaba un color
        // cualquiera.
        startRunning()
        await Self.waitForMetering(on: device)
        try UltraWideCamera.lockExposureAndWhiteBalance(on: device, settings: settings, applied: &applied)
        self.applied = applied
        return applied
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
        guard let settings, let applied else {
            throw CameraSetupError.noUltraWideCamera
        }

        // Un fichero por arranque, con el lado en el nombre: en el servidor hay que
        // poder saber cuál es cuál sin abrirlos.
        let side = settings.role == .left ? "left" : "right"
        let name = "\(side)-\(Int(Date().timeIntervalSince1970)).mov"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)

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

        queue.async { [weak self] in
            guard let self else { return }
            // Si había una grabación abierta (dos toques seguidos), se cierra antes.
            self.closeWriter()
            self.writer = writer
            self.writerInput = input
            self.writerStarted = false
        }
        return url.path
    }

    func stopRecording() {
        queue.async { [weak self] in
            self?.closeWriter()
        }
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
                writer.finishWriting {}
            } else {
                writer.cancelWriting()
            }
        }
        self.writer = nil
        writerInput = nil
        writerStarted = false
    }

    func stop() {
        stopRecording()
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
            batteryLevel: Double(UIDevice.current.batteryLevel),
            freeDiskBytes: Self.freeDiskBytes(),
            droppedFrames: droppedFrames,
            timecodeFailures: timecodeFailures
        )
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
        let rigTime = CMTimeAdd(original, CMTime(value: clockOffsetNs, timescale: 1_000_000_000))

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
        if let retimed = Self.retimed(sampleBuffer, to: rigTime) {
            input.append(retimed)
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
