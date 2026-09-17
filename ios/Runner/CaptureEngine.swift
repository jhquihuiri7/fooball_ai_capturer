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

    // MARK: - Ciclo de vida

    func hasUltraWideCamera() -> Bool {
        UltraWideCamera.discover() != nil
    }

    func configure(_ settings: CaptureSettings) throws -> AppliedCameraSettings {
        guard let device = UltraWideCamera.discover() else {
            throw CameraSetupError.noUltraWideCamera
        }

        session.beginConfiguration()
        // `inputPriority` es obligatorio antes de tocar `activeFormat`: con cualquier
        // preset, la sesión reescribe el formato al aplicar la configuración y todo el
        // trabajo de `lockSettings` se pierde en silencio.
        session.sessionPreset = .inputPriority

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
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        session.commitConfiguration()

        let applied = try UltraWideCamera.lockSettings(on: device, settings: settings)
        if let connection = output.connection(with: .video) {
            let result = UltraWideCamera.configure(connection: connection)
            stabilizationOff = result.stabilizationOff
            intrinsicsAvailable = result.intrinsics
        }

        self.device = device
        self.settings = settings
        self.applied = applied
        return applied
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

    func startRecording(directory: String) throws {
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
            self?.writer = writer
            self?.writerInput = input
            self?.writerStarted = false
        }
    }

    func stopRecording() {
        queue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            self.writerInput?.markAsFinished()
            writer.finishWriting {}
            self.writer = nil
            self.writerInput = nil
            self.writerStarted = false
        }
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
            whiteBalanceLocked: applied?.whiteBalanceLocked ?? false,
            focusLocked: applied?.focusLocked ?? false,
            intrinsicsAvailable: intrinsicsAvailable,
            thermalState: Self.thermalState(),
            batteryLevel: Double(UIDevice.current.batteryLevel),
            freeDiskBytes: Self.freeDiskBytes(),
            droppedFrames: droppedFrames
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

        guard let writer, let input = writerInput else { return }

        if !writerStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: rigTime)
            writerStarted = true
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
