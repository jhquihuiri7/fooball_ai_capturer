// Descubrimiento y bloqueo de la ultra gran angular (ADR 0012, TASK A2).
//
// Todo lo que hay aquí existe por una razón concreta del ADR, no por gusto. Los tres
// que más duelen si se olvidan:
//
//   1. La estabilización recorta y desplaza la imagen, y con ella la rotación calibrada
//      entre las dos cámaras deja de valer a mitad de partido, sin dar ningún error.
//   2. La exposición automática cambia el brillo de cada cámara por su cuenta, y la
//      costura aparece como una línea vertical de otro color en cuanto entra una nube.
//   3. Una obturación que no sea múltiplo de la red eléctrica produce bandas con los
//      focos del campo, y ninguna corrección posterior las quita.
//
// NO COMPILADO. Se escribió en Windows: no ha pasado por Xcode ni por un dispositivo.

import AVFoundation

enum CameraSetupError: LocalizedError {
    case noUltraWideCamera
    case noFormat(width: Int, height: Int, fps: Int)

    var errorDescription: String? {
        switch self {
        case .noUltraWideCamera:
            return "este iPhone no tiene camara ultra gran angular"
        case let .noFormat(width, height, fps):
            return "la ultra gran angular no admite \(width)x\(height) a \(fps) fps"
        }
    }
}

/// Lo que se consiguió aplicar de verdad. Se comprueba y se devuelve porque
/// AVFoundation acepta peticiones que luego no cumple.
struct AppliedCameraSettings {
    var width: Int
    var height: Int
    var actualFps: Double
    var exposureLocked: Bool
    var whiteBalanceLocked: Bool
    var focusLocked: Bool
}

enum UltraWideCamera {
    /// La cámara ultra gran angular trasera, si la hay.
    ///
    /// Con `DiscoverySession` y nunca con una lista de modelos: Veo Go rechazó el
    /// iPhone 17 Pro por tener la lista desactualizada, y ese fallo es evitable.
    static func discover() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .back
        ).devices.first
    }

    /// El formato más ajustado a lo pedido.
    ///
    /// Se busca coincidencia exacta de resolución: un 4K que en realidad sea 1080p
    /// escalado destruye el balón de 6 px y nadie se entera hasta ver la grabación.
    static func bestFormat(
        for device: AVCaptureDevice,
        width: Int,
        height: Int,
        fps: Int
    ) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) == width, Int(dimensions.height) == height else {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(fps) && Double(fps) <= range.maxFrameRate
            }
        }
    }

    /// Aplica los ajustes del ADR 0012 y devuelve lo que quedó puesto.
    static func lockSettings(
        on device: AVCaptureDevice,
        settings: CaptureSettings
    ) throws -> AppliedCameraSettings {
        let width = Int(settings.width)
        let height = Int(settings.height)
        let fps = Int(settings.fps)

        guard let format = bestFormat(for: device, width: width, height: height, fps: fps) else {
            throw CameraSetupError.noFormat(width: width, height: height, fps: fps)
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        // Fijar el mismo mínimo y máximo desactiva la cadencia variable. Sin esto, con
        // poca luz el iPhone baja a 24 fps por su cuenta y las dos cámaras dejan de ir
        // a la misma velocidad, que es justo lo que el servidor rechaza.
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        // Obturación múltiplo de la frecuencia de la red, e ISO acotado a lo que el
        // formato admite: pedir un ISO fuera de rango es una excepción, no un recorte.
        let shutter = CMTime(value: 1, timescale: CMTimeScale(settings.shutterDenominator))
        let iso = min(max(Float(settings.iso), format.minISO), format.maxISO)
        var exposureLocked = false
        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(duration: shutter, iso: iso, completionHandler: nil)
            exposureLocked = true
        }

        // El balance se congela con las ganancias que la cámara tenga ahora mismo, así
        // que quien monta el soporte debe apuntar ya al campo antes de configurar.
        var whiteBalanceLocked = false
        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
            whiteBalanceLocked = true
        }

        // La ultra gran angular de los iPhone 11 y 12 es de foco fijo: ahí no hay nada
        // que bloquear, y no es un fallo.
        var focusLocked = true
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        } else {
            focusLocked = !device.isFocusModeSupported(.continuousAutoFocus)
        }

        // Corrección geométrica: da igual activada o desactivada mientras los dos
        // móviles coincidan, pero tiene que ser explícito. Activada es mejor porque
        // deja la imagen rectilínea, que es lo que supone el modelo pinhole del
        // servidor (`libs/vision/rig.py`).
        if device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = true
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return AppliedCameraSettings(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            actualFps: 1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration),
            exposureLocked: exposureLocked,
            whiteBalanceLocked: whiteBalanceLocked,
            focusLocked: focusLocked
        )
    }

    /// Deja la conexión como la necesita el soporte y dice si lo consiguió.
    ///
    /// Devuelve si la estabilización quedó desactivada de verdad: es la comprobación
    /// que `CaptureSession` mira en Dart para negarse a grabar.
    @discardableResult
    static func configure(connection: AVCaptureConnection) -> (stabilizationOff: Bool, intrinsics: Bool) {
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        // La matriz intrínseca por frame ahorra media calibración, y además sobrevive a
        // que el sistema cambie el recorte activo sin avisar.
        var intrinsics = false
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            intrinsics = true
        }

        return (connection.activeVideoStabilizationMode == .off, intrinsics)
    }
}
