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
    var exposureLocked = false
    var exposureSeconds = 0.0
    var iso: Float = 0
    var whiteBalanceLocked = false
    var whiteBalanceKelvin: Float = 0
    var whiteBalanceTint: Float = 0
    var focusLocked: Bool
}

/// Cómo «ve» una cámara: lo que el maestro le pasa al otro móvil para que las dos mitades
/// de la panorámica salgan del mismo color y con la misma luz.
///
/// Viaja en unidades que no dependen del móvil: el balance en temperatura y tinte (las
/// ganancias son de cada sensor) y la apertura junto al ISO, para que un móvil con otra
/// lente compense la luz que le entra de más o de menos.
struct CameraLook: Equatable {
    var exposureNs: Int64
    var iso: Float
    var aperture: Float
    var kelvin: Float
    var tint: Float

    /// El ISO que da la misma luz con otra apertura: la luz va con el cuadrado del número f.
    func iso(forAperture other: Float) -> Float {
        guard aperture > 0, other > 0 else { return iso }
        return iso * (other * other) / (aperture * aperture)
    }
}

enum UltraWideCamera {
    /// Posición de la lente para el infinito. AVFoundation la normaliza de 0 (lo más
    /// cerca) a 1 (lo más lejos), sin unidades ni distancia real.
    static let infinityLensPosition: Float = 1.0

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

        // Exposición y balance en automático por ahora: la cámara tiene que medir la
        // luz del campo antes de que `lockExposureAndWhiteBalance` congele lo medido.
        // Quien monta el soporte debe apuntar ya al campo al configurar.
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // BT.709 en las dos cámaras. Es lo que espera el servidor (OpenCV y FFmpeg no
        // miran las primarias) y lo único que garantiza que el color sea el mismo en
        // los dos móviles aunque un formato admita P3 y otro no.
        if format.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }

        // Sin HDR de sensor: mezcla exposiciones frame a frame con una curva que cambia
        // sola, y dos móviles no la cambian igual. La costura se vería.
        if format.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }

        // Foco al infinito, y no «donde esté la lente ahora»: en los Pro la ultra gran
        // angular enfoca hasta macro, y si la app arranca con el móvil sobre una mesa la
        // lente se queda a dos centímetros y el campo sale borroso. A 13 mm todo lo que
        // esté a más de un metro es nítido con la lente en el infinito, así que es el
        // único valor que vale igual para las dos cámaras. La ultra gran angular de los
        // iPhone 11 y 12 es de foco fijo: ahí no hay nada que mover, y no es un fallo.
        var focusLocked = true
        if device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: infinityLensPosition, completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
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
            focusLocked: focusLocked
        )
    }

    /// Congela exposición y balance con lo que la cámara acaba de medir.
    ///
    /// La luz total (ISO por tiempo) se conserva, pero el tiempo se lleva a la obturación
    /// sin parpadeo: un semiperiodo de la red (1/100 a 50 Hz). Si al ISO mínimo sobra
    /// luz, es de día y no hay red que parpadee, así que se acorta la obturación. Si al
    /// ISO máximo falta luz, se abre a dos semiperiodos, que siguen sin dar bandas; y si
    /// ni así llega, queda oscuro y la pantalla lo enseña.
    static func lockExposureAndWhiteBalance(
        on device: AVCaptureDevice,
        settings: CaptureSettings,
        applied: inout AppliedCameraSettings
    ) throws {
        let format = device.activeFormat
        let halfPeriod = 1.0 / Double(settings.shutterDenominator)
        let measuredSeconds = CMTimeGetSeconds(device.exposureDuration)
        let measuredIso = Double(device.iso)
        let measuredLight = measuredIso * measuredSeconds

        var seconds = halfPeriod
        var iso = measuredLight / seconds
        if !iso.isFinite || iso <= 0 {
            // La cámara no llegó a medir: el ISO de reserva del contrato.
            iso = Double(settings.iso)
        } else if iso < Double(format.minISO) {
            iso = Double(format.minISO)
            seconds = measuredLight / iso
        } else if iso > Double(format.maxISO) {
            seconds = 2 * halfPeriod
            iso = measuredLight / seconds
        }
        iso = min(max(iso, Double(format.minISO)), Double(format.maxISO))
        seconds = min(
            max(seconds, CMTimeGetSeconds(format.minExposureDuration)),
            CMTimeGetSeconds(format.maxExposureDuration)
        )

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(
                duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                iso: Float(iso),
                completionHandler: nil
            )
            applied.exposureLocked = true
        }
        applied.exposureSeconds = seconds
        applied.iso = Float(iso)

        // Las ganancias se acotan porque fuera de rango no es un recorte: es una
        // excepción que tira la app.
        if device.isWhiteBalanceModeSupported(.locked) {
            var gains = device.deviceWhiteBalanceGains
            let top = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), top)
            gains.greenGain = min(max(gains.greenGain, 1), top)
            gains.blueGain = min(max(gains.blueGain, 1), top)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            applied.whiteBalanceLocked = true
            let values = device.temperatureAndTintValues(for: gains)
            applied.whiteBalanceKelvin = values.temperature
            applied.whiteBalanceTint = values.tint
        }
    }

    /// Pone la exposición y el balance del maestro en vez de los medidos por este móvil.
    ///
    /// La obturación se copia tal cual (ya viene sin parpadeo) y el ISO se corrige por la
    /// apertura. Todo se acota al formato: fuera de rango AVFoundation no recorta, lanza.
    static func apply(
        look: CameraLook,
        on device: AVCaptureDevice,
        applied: inout AppliedCameraSettings
    ) throws {
        let format = device.activeFormat
        let seconds = min(
            max(Double(look.exposureNs) / 1_000_000_000, CMTimeGetSeconds(format.minExposureDuration)),
            CMTimeGetSeconds(format.maxExposureDuration)
        )
        let iso = min(max(look.iso(forAperture: device.lensAperture), format.minISO), format.maxISO)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(
                duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                iso: iso,
                completionHandler: nil
            )
            applied.exposureLocked = true
            applied.exposureSeconds = seconds
            applied.iso = iso
        }
        if device.isWhiteBalanceModeSupported(.locked), look.kelvin > 0 {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: look.kelvin,
                tint: look.tint
            )
            var gains = device.deviceWhiteBalanceGains(for: values)
            let top = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), top)
            gains.greenGain = min(max(gains.greenGain, 1), top)
            gains.blueGain = min(max(gains.blueGain, 1), top)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            applied.whiteBalanceLocked = true
            applied.whiteBalanceKelvin = look.kelvin
            applied.whiteBalanceTint = look.tint
        }
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
