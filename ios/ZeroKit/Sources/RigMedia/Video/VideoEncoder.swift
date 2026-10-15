// El codificador H.264 del programa (IOS-50, ADR 0021 y 0022).
//
// VTCompressionSession en modo de baja latencia y tamaño fijo: sin reordenar
// fotogramas (cada fotograma sale al enlace en cuanto está), GOP atado al segmento del
// VPS (`PROGRAM_GOP_S`) y QP con tope para que un pico de movimiento no cuele un
// fotograma de papilla del que cuelga el resto del GOP.
//
// Cada muestra sale en AVCC con la SEI del tiempo del soporte DENTRO de su unidad de
// acceso (H264Sei, ADR 0022): el rigMs viaja con el fotograma y sobrevive al PES, a
// HLS y a cualquier relé. La salida va a una BoundedQueue con descarte de lo viejo:
// si quien consume se atasca, se tira y se pide IDR, nunca se encola latencia.
//
// 2026-10-14: la sesión se rehace sola si iOS la invalida (kVTInvalidSessionErr). Pasa al
// volver del segundo plano (el botón lateral, contestar una llamada, cambiar de app): sin
// esto el programa y la parte no volvían a salir hasta PARAR y EMITIR, con la pantalla
// diciendo EMITIENDO. Es lo que hace WebRTC con el mismo error.

import CoreMedia
import Foundation
import RigCore
import VideoToolbox

/// Un fotograma codificado, listo para el enlace o el mux.
public struct EncodedFrame {
    /// La muestra AVCC (longitudes de 4 bytes), con nuestra SEI delante.
    public let data: Data
    public let isKeyframe: Bool
    /// El tiempo del soporte del fotograma, en ms. El mismo que va dentro, en la SEI.
    public let rigMs: UInt64
    /// Qué cámara es: 0 la izquierda, 1 la derecha.
    public let viewId: UInt8
    /// El PTS con el que entró al codificador, en ns.
    public let ptsNs: Int64
    /// La descripción de formato (SPS/PPS). Va en todos: al receptor le basta leerla
    /// cuando cambie, y aquí no se decide por él.
    public let formatDescription: CMFormatDescription?
}

public final class VideoEncoder {
    public enum EncoderError: Error, Equatable {
        case create(OSStatus)
        case property(OSStatus)
    }

    /// La sesión de VideoToolbox; se cambia (bajo `lock`) si iOS la invalida.
    private var session: VTCompressionSession
    private let width: Int
    private let height: Int
    /// El bitrate vigente, para rehacer la sesión con el mismo.
    private var bitrateBps: Int
    /// Un fotograma volvió con la sesión invalidada: el siguiente `encode` la rehace.
    private var needsNewSession = false
    /// Las veces que se rehízo la sesión (para el informe).
    public private(set) var sessionResets = 0
    private let viewId: UInt8
    private let lock = NSLock()
    private var queue: BoundedQueue<EncodedFrame>
    private var forceNextIDR = false
    /// Fotogramas que el codificador devolvió con error o vacíos.
    public private(set) var encodeFailures = 0
    /// 2026-10-14: fotogramas entregados a VideoToolbox que aún no han vuelto, y lo más
    /// que llegaron a ser. Cada uno retiene su búfer del pool de quien lo pinta: un
    /// codificador atascado hace crecer ese pool (el salto de +180 MB del maestro en el
    /// ensayo de 90 min sigue sin causa; esto dice si fue eso).
    private var submitted = 0
    private var completed = 0
    private var submitErrors = 0
    private var inFlightMax = 0

    public init(width: Int, height: Int, bitrateBps: Int, viewId: UInt8) throws {
        self.viewId = viewId
        self.width = width
        self.height = height
        self.bitrateBps = bitrateBps
        queue = BoundedQueue(capacity: VideoConstants.encodedQueueSlots, policy: .dropOldest)
        session = try Self.makeSession(width: width, height: height, bitrateBps: bitrateBps)
    }

    /// Una sesión de baja latencia lista para codificar, con los ajustes del programa.
    private static func makeSession(width: Int, height: Int, bitrateBps: Int) throws -> VTCompressionSession {
        var created: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        // NV12 lineal y Metal-compatible. Sin esto el pool entrega el formato
        // comprimido sin pérdida de Apple ('&8v0'), cuya memoria no es stride×alto:
        // escribirlo por CPU se sale del búfer, y el render escribe por Metal igual.
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw EncoderError.create(status)
        }
        do {
            try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
            try set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
            try set(
                session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                VideoConstants.programGopS as CFNumber
            )
            // Solo existe en baja latencia; si el cacharro no lo soporta, no es un error.
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                value: VideoConstants.maxAllowedFrameQp as CFNumber
            )
            try apply(session, bitrateBps: bitrateBps)
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// La sesión vigente.
    private var current: VTCompressionSession {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    /// El pool del codificador, para que el render escriba directo en sus búferes. Se pide
    /// en cada fotograma: si la sesión se rehízo, el pool es otro.
    public var pixelBufferPool: CVPixelBufferPool? {
        VTCompressionSessionGetPixelBufferPool(current)
    }

    /// Cambia el bitrate en marcha (la escalera de degradación lo pide).
    public func setBitrate(bps: Int) throws {
        try Self.apply(current, bitrateBps: bps)
        lock.lock()
        bitrateBps = bps
        lock.unlock()
    }

    /// Cambia la sesión invalidada por una nueva con los mismos ajustes. La primera
    /// muestra de la nueva sale IDR: el receptor arranca de ella. false si no se pudo
    /// (se reintenta en el siguiente fotograma).
    @discardableResult
    private func replaceSession(_ vieja: VTCompressionSession) -> Bool {
        lock.lock()
        let bps = bitrateBps
        lock.unlock()
        guard let nueva = try? Self.makeSession(width: width, height: height, bitrateBps: bps) else {
            lock.lock()
            needsNewSession = true
            lock.unlock()
            return false
        }
        lock.lock()
        // Otro hilo pudo cambiarla ya: entonces sobra esta.
        guard session === vieja else {
            lock.unlock()
            VTCompressionSessionInvalidate(nueva)
            return true
        }
        session = nueva
        needsNewSession = false
        sessionResets += 1
        lock.unlock()
        VTCompressionSessionInvalidate(vieja)
        return true
    }

    /// Para las pruebas: lo que le hace iOS a la sesión al pasar a segundo plano.
    func invalidateSessionForTesting() {
        VTCompressionSessionInvalidate(current)
    }

    /// El siguiente fotograma sale IDR (el receptor lo pide tras un hueco).
    public func forceIDR() {
        lock.lock()
        forceNextIDR = true
        lock.unlock()
    }

    /// Codifica un fotograma. No bloquea: la muestra aparece en la cola al completar.
    public func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64, rigMs: UInt64) {
        lock.lock()
        let idr = forceNextIDR
        forceNextIDR = false
        lock.unlock()

        var properties: CFDictionary?
        if idr {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let pts = CMTime(value: ptsNs, timescale: 1_000_000_000)
        lock.lock()
        let rehacer = needsNewSession
        let sesion = session
        lock.unlock()
        if rehacer { replaceSession(sesion) }
        let status = submit(pixelBuffer, pts: pts, properties: properties, ptsNs: ptsNs, rigMs: rigMs)
        // Invalidada (al volver del segundo plano): una nueva y el mismo fotograma otra vez.
        if status == kVTInvalidSessionErr, replaceSession(sesion) {
            _ = submit(pixelBuffer, pts: pts, properties: properties, ptsNs: ptsNs, rigMs: rigMs)
        }
    }

    /// Entrega un fotograma a la sesión vigente; cuenta el fallo si no lo acepta.
    private func submit(
        _ pixelBuffer: CVPixelBuffer, pts: CMTime, properties: CFDictionary?, ptsNs: Int64, rigMs: UInt64
    ) -> OSStatus {
        lock.lock()
        submitted += 1
        inFlightMax = max(inFlightMax, submitted - completed - submitErrors)
        let sesion = session
        lock.unlock()
        let status = VTCompressionSessionEncodeFrame(
            sesion,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            self?.finish(status: status, sampleBuffer: sampleBuffer, ptsNs: ptsNs, rigMs: rigMs)
        }
        if status != noErr {
            lock.lock()
            encodeFailures += 1
            submitErrors += 1
            lock.unlock()
        }
        return status
    }

    /// Fotogramas en VideoToolbox ahora mismo.
    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, submitted - completed - submitErrors)
    }

    /// Lo más que hubo en VideoToolbox desde la última vez que se preguntó (o desde el
    /// principio), y vuelve a empezar a contar desde lo que hay ahora.
    public func takeInFlightPeak() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let pico = inFlightMax
        inFlightMax = max(0, submitted - completed - submitErrors)
        return pico
    }

    /// Vacía lo pendiente del codificador (fin de la emisión o un test).
    public func flush() {
        VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
    }

    /// El fotograma codificado más viejo que espera, o `nil`.
    public func pop() -> EncodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return queue.pop()
    }

    /// (encolados, sacados, tirados) de la cola de salida, para la telemetría.
    public var queueCounts: (pushed: Int, popped: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (queue.pushed, queue.popped, queue.dropped)
    }

    // MARK: - Dentro

    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw EncoderError.property(status) }
    }

    private static func apply(_ session: VTCompressionSession, bitrateBps: Int) throws {
        try set(session, kVTCompressionPropertyKey_AverageBitRate, bitrateBps as CFNumber)
        // Los DataRateLimits van en bytes por ventana: el margen deja respirar al IDR.
        let bytes = Int(
            Double(bitrateBps) / 8.0
                * VideoConstants.dataRateWindowS * VideoConstants.dataRateBurstRatio
        )
        try set(
            session, kVTCompressionPropertyKey_DataRateLimits,
            [bytes, VideoConstants.dataRateWindowS] as CFArray
        )
    }

    private func finish(status: OSStatus, sampleBuffer: CMSampleBuffer?, ptsNs: Int64, rigMs: UInt64) {
        lock.lock()
        completed += 1
        // Invalidada a medio codificar: el siguiente `encode` la rehace.
        if status == kVTInvalidSessionErr { needsNewSession = true }
        lock.unlock()
        guard status == noErr,
              let sampleBuffer,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            lock.lock()
            encodeFailures += 1
            lock.unlock()
            return
        }

        // El bloque puede no ser contiguo: se copia entero, no se lee de un puntero.
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { destino in
            CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length,
                destination: destino.baseAddress!
            )
        }
        guard copied == noErr else {
            lock.lock()
            encodeFailures += 1
            lock.unlock()
            return
        }

        // Sin la marca NotSync es un fotograma de sincronización (IDR).
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false

        let frame = EncodedFrame(
            data: H264Sei.insert(intoAvcc: avcc, rigMs: rigMs, viewId: viewId),
            isKeyframe: !notSync,
            rigMs: rigMs,
            viewId: viewId,
            ptsNs: ptsNs,
            formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        lock.lock()
        queue.push(frame)
        lock.unlock()
    }
}
