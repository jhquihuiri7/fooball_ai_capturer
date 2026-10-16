// El vídeo MP4 del programa (IOS-103, ADR 0027 decisión 4): a pantalla completa, por
// encima del gráfico, y con su sonido en lugar del micro.
//
// Dos AVAssetReader sobre el mismo fichero, uno por pista, para que leer el audio por
// delante nunca espere al vídeo ni al revés. El de vídeo decodifica en su cola, escala
// cada fotograma al tamaño del programa con bandas (VTPixelTransferSession en modo
// letterbox, como las miniaturas) en búferes de un pool preasignado, y los deja en un
// anillo acotado; el programa toma, para su instante, el último fotograma que ya debía
// verse. El de audio sale ya a 48 kHz estéreo en Float32 (remuestrea el lector) y queda en
// una cola por delante; el AAC del programa se lo pide por su eje (ProgramAudioSubstitute).
//
// El cero del vídeo es `startRigMs`, en el reloj del programa: lo que en el fichero pasa en
// el instante m se ve en el programa en startRigMs + m y su sonido se sella igual, así que
// audio y vídeo van juntos en el TS sin mirarse. Un vídeo grabado en vertical se endereza
// con la composición de sus propiedades; uno sin audio suena a silencio, no a micro.

import AVFoundation
import CoreVideo
import Foundation
import RigCore
import VideoToolbox

public enum ProgramVideoConstants {
    /// Fotogramas ya escalados que el lector deja por delante: 12 son 0,4 s a 30 fps. Con el
    /// que se ve y los que tiene el codificador, el pool reserva `frameSlots + poolSpare`
    /// NV12 de 1080p (~3 MB cada uno) al abrir, no en el bucle.
    public static let frameSlots = 12
    static let poolSpare = 4
    /// Audio que el lector deja preparado por delante, en ms: holgado sobre lo que el AAC
    /// pide de una vez (el vigilante rellena hasta 200 ms de golpe).
    public static let audioAheadMs = 500.0
    /// Si el eje del AAC pide más lejos de lo preparado que esto, en ms, se salta audio o
    /// se mete silencio para volver a casar; por debajo se sigue muestra a muestra.
    public static let audioResyncMs = 40.0
    /// Lo que espera un lector, en ms, con su cola llena antes de volver a mirar.
    static let readerIdleMs = 20
    /// Muestras ya servidas que se dejan en la cola de audio antes de compactarla: un
    /// segundo, para no mover memoria en cada trozo.
    static let audioCompactSamples = AudioConstants.sampleRate
    /// NV12 de rango de vídeo: el negro de las bandas y del fotograma que aún no llegó.
    static let blackLuma: UInt8 = 16
    static let neutralChroma: UInt8 = 128
}

public final class ProgramVideoPlayer: ProgramAudioSubstitute {
    public enum PlayerError: Error, Equatable {
        case noVideoTrack
        case reader(String)
        case pool
        case transfer
    }

    /// La reproducción (`video/play` de Dart): vuelve en el aviso de fin.
    public let id: Int64
    public let startRigMs: Double
    public let durationMs: Double
    public let width: Int
    public let height: Int

    private let videoReader: AVAssetReader
    private let videoOut: AVAssetReaderOutput
    private let audioReader: AVAssetReader?
    private let audioOut: AVAssetReaderOutput?
    private let transfer: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let black: CVPixelBuffer
    private let videoQueue = DispatchQueue(label: "io.footballai.zero.video.frames", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "io.footballai.zero.video.audio", qos: .userInitiated)
    private let videoSpace = DispatchSemaphore(value: 0)
    private let audioSpace = DispatchSemaphore(value: 0)
    private let rate = Double(AudioConstants.sampleRate)

    // Con `lock`.
    private let lock = NSLock()
    private var frames: [(ms: Double, buffer: CVPixelBuffer)] = []
    private var shown: CVPixelBuffer?
    private var videoDone = false
    private var failure: String?
    private var stopped = false
    private var started = false
    /// El audio preparado, un vector por canal; `pcmRead` es la primera muestra sin servir y
    /// `pcmStart` la muestra del fichero (a 48 kHz) que es `pcm[_][0]`.
    private var pcm: [[Float]] = Array(repeating: [], count: AudioConstants.programChannels)
    private var pcmRead = 0
    private var pcmStart: Int?
    private var audioDone = false
    private var underrunCount = 0

    /// Abre `url` y prepara los lectores; no lee hasta `start`. Lanza si no hay pista de
    /// vídeo, si el lector no arranca (un códec que no se decodifica) o sin memoria.
    public static func open(
        url: URL, id: Int64, startRigMs: Double, width: Int, height: Int
    ) async throws -> ProgramVideoPlayer {
        let asset = AVURLAsset(url: url)
        guard let pista = try await asset.loadTracks(withMediaType: .video).first else {
            throw PlayerError.noVideoTrack
        }
        let duracion = CMTimeGetSeconds(try await asset.load(.duration)) * 1000
        let giro = try await pista.load(.preferredTransform)

        let lectorVideo = try AVAssetReader(asset: asset)
        let salidaVideo: AVAssetReaderOutput
        if giro.isIdentity {
            let t = AVAssetReaderTrackOutput(track: pista, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            t.alwaysCopiesSampleData = false
            salidaVideo = t
        } else {
            // Grabado en vertical (o girado): la composición de sus propiedades lo endereza.
            // Sale en BGRA, que es lo que da el compositor; la transferencia lo pasa a NV12.
            let c = AVAssetReaderVideoCompositionOutput(videoTracks: [pista], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            c.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            c.alwaysCopiesSampleData = false
            salidaVideo = c
        }
        guard lectorVideo.canAdd(salidaVideo) else { throw PlayerError.reader("la pista de vídeo no se puede leer") }
        lectorVideo.add(salidaVideo)

        var lectorAudio: AVAssetReader?
        var salidaAudio: AVAssetReaderOutput?
        let pistasAudio = try await asset.loadTracks(withMediaType: .audio)
        if !pistasAudio.isEmpty {
            let lector = try AVAssetReader(asset: asset)
            let salida = AVAssetReaderAudioMixOutput(audioTracks: pistasAudio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioConstants.sampleRate,
                AVNumberOfChannelsKey: AudioConstants.programChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            salida.alwaysCopiesSampleData = false
            if lector.canAdd(salida) {
                lector.add(salida)
                lectorAudio = lector
                salidaAudio = salida
            }
        }

        let jugador = try ProgramVideoPlayer(
            id: id, startRigMs: startRigMs, durationMs: duracion, width: width, height: height,
            videoReader: lectorVideo, videoOut: salidaVideo, audioReader: lectorAudio, audioOut: salidaAudio
        )
        guard lectorVideo.startReading() else {
            throw PlayerError.reader(lectorVideo.error?.localizedDescription ?? "el vídeo no se puede decodificar")
        }
        if let lectorAudio, !lectorAudio.startReading() {
            // Sin su sonido sigue el vídeo, con silencio: mejor que el micro a destiempo.
            jugador.lock.lock()
            jugador.audioDone = true
            jugador.lock.unlock()
        }
        return jugador
    }

    private init(
        id: Int64, startRigMs: Double, durationMs: Double, width: Int, height: Int,
        videoReader: AVAssetReader, videoOut: AVAssetReaderOutput,
        audioReader: AVAssetReader?, audioOut: AVAssetReaderOutput?
    ) throws {
        var s: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else {
            throw PlayerError.transfer
        }
        VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil,
            [kCVPixelBufferPoolMinimumBufferCountKey: ProgramVideoConstants.frameSlots + ProgramVideoConstants.poolSpare]
                as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &p
        )
        guard let p else { throw PlayerError.pool }
        var negro: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, p, &negro)
        guard let negro else { throw PlayerError.pool }
        Self.paintBlack(negro)
        self.id = id
        self.startRigMs = startRigMs
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.videoReader = videoReader
        self.videoOut = videoOut
        self.audioReader = audioReader
        self.audioOut = audioOut
        transfer = s
        pool = p
        black = negro
        audioDone = audioOut == nil
    }

    deinit {
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// Echa a andar los dos lectores. Una vez.
    public func start() {
        lock.lock()
        let ya = started
        started = true
        lock.unlock()
        guard !ya else { return }
        videoQueue.async { self.pumpVideo() }
        audioQueue.async { self.pumpAudio() }
    }

    /// Para los lectores y suelta los fotogramas. El programa y el AAC vuelven a lo suyo.
    public func stop() {
        lock.lock()
        stopped = true
        frames.removeAll()
        shown = nil
        lock.unlock()
        videoSpace.signal()
        audioSpace.signal()
        videoQueue.async { self.videoReader.cancelReading() }
        audioQueue.async { self.audioReader?.cancelReading() }
    }

    /// Si en el instante `t` del programa el vídeo ya no tiene nada que poner: pasó su
    /// duración, se paró o el lector falló.
    public func isFinished(atRigMs t: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped || failure != nil || t - startRigMs >= durationMs
    }

    /// Por qué falló el lector, si falló.
    public var failureReason: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// Veces que el AAC pidió audio que el lector aún no tenía (se rellenó de silencio).
    public var underruns: Int {
        lock.lock(); defer { lock.unlock() }
        return underrunCount
    }

    /// Hasta dónde hay fotogramas preparados, en ms del fichero; y si el lector acabó.
    public var buffered: (videoMs: Double?, videoDone: Bool, audioMs: Double?, audioDone: Bool) {
        lock.lock(); defer { lock.unlock() }
        let audio = pcmStart.map { Double($0 + pcm[0].count) * 1000 / rate }
        return (frames.last?.ms, videoDone, audio, audioDone)
    }

    /// El fotograma del programa para su instante `t`: el último del fichero que ya debía
    /// verse, a `width × height` con bandas. Negro si el vídeo empezó y el lector aún no
    /// entregó nada; nil antes de su cero, pasada su duración o parado.
    public func frame(atRigMs t: Double) -> CVPixelBuffer? {
        let m = t - startRigMs
        guard m >= 0, m < durationMs else { return nil }
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return nil
        }
        var sueltos = 0
        while let primero = frames.first, primero.ms <= m {
            shown = primero.buffer
            frames.removeFirst()
            sueltos += 1
        }
        let salida = shown ?? black
        lock.unlock()
        if sueltos > 0 { videoSpace.signal() }
        return salida
    }

    // MARK: - ProgramAudioSubstitute

    /// `count` muestras del sonido del vídeo para el trozo del AAC que empieza en `rigMs`:
    /// nil fuera del vídeo (suena el micro). Lo que falte (antes del cero, un hueco, el
    /// lector por detrás, un vídeo mudo) va en silencio.
    public func samples(count: Int, atRigMs rigMs: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let m0 = rigMs - startRigMs
        guard count > 0, m0 + Double(count) * 1000 / rate > 0, m0 < durationMs,
              let salida = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let datos = salida.floatChannelData
        else { return nil }
        let canales = Int(format.channelCount)
        salida.frameLength = AVAudioFrameCount(count)
        for c in 0..<canales {
            datos[c].update(repeating: 0, count: count)
        }
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return nil
        }
        let quiero = Int((m0 * rate / 1000).rounded())
        let tolerancia = Int(ProgramVideoConstants.audioResyncMs * rate / 1000)
        var servidas = 0
        if let inicio = pcmStart {
            var siguiente = inicio + pcmRead
            // Por detrás de lo que pide el eje: se salta lo que ya no toca.
            if siguiente < quiero - tolerancia {
                let saltar = min(quiero - siguiente, pcm[0].count - pcmRead)
                pcmRead += saltar
                siguiente += saltar
            }
            // Por delante (o antes del cero): silencio hasta casar.
            let desde = (siguiente > quiero + tolerancia || quiero < 0) ? min(count, max(0, siguiente - quiero)) : 0
            let n = min(count - desde, pcm[0].count - pcmRead)
            if n > 0 {
                for c in 0..<canales {
                    let origen = pcm[min(c, pcm.count - 1)]
                    origen.withUnsafeBufferPointer { b in
                        (datos[c] + desde).update(from: b.baseAddress! + pcmRead, count: n)
                    }
                }
                pcmRead += n
                servidas = n
            }
            if desde + servidas < count, !audioDone { underrunCount += 1 }
            if pcmRead >= ProgramVideoConstants.audioCompactSamples {
                for c in pcm.indices { pcm[c].removeFirst(pcmRead) }
                pcmStart = inicio + pcmRead
                pcmRead = 0
            }
        } else if !audioDone, m0 >= 0 {
            underrunCount += 1
        }
        lock.unlock()
        if servidas > 0 { audioSpace.signal() }
        return salida
    }

    // MARK: - Los lectores, cada uno en su cola

    private func pumpVideo() {
        while true {
            lock.lock()
            let parar = stopped
            let lleno = frames.count >= ProgramVideoConstants.frameSlots
            lock.unlock()
            if parar { return }
            if lleno {
                _ = videoSpace.wait(timeout: .now() + .milliseconds(ProgramVideoConstants.readerIdleMs))
                continue
            }
            // Un lector que no está leyendo lanza una excepción de Objective-C al pedirle
            // muestras: se mira antes.
            guard videoReader.status == .reading, let muestra = videoOut.copyNextSampleBuffer() else {
                lock.lock()
                videoDone = true
                if videoReader.status == .failed, !stopped {
                    failure = videoReader.error?.localizedDescription ?? "el lector de vídeo falló"
                }
                lock.unlock()
                return
            }
            guard let fuente = CMSampleBufferGetImageBuffer(muestra) else { continue }
            let ms = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(muestra)) * 1000
            var destino: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destino)
            // Un fotograma que no se escala no entra: se sigue viendo el anterior.
            guard let destino, VTPixelTransferSessionTransferImage(transfer, from: fuente, to: destino) == noErr else {
                continue
            }
            lock.lock()
            if !stopped { frames.append((ms, destino)) }
            lock.unlock()
        }
    }

    private func pumpAudio() {
        guard let audioOut, let audioReader else { return }
        let canales = AudioConstants.programChannels
        while true {
            lock.lock()
            let parar = stopped || audioDone
            let porDelante = Double(pcm[0].count - pcmRead) * 1000 / rate
            lock.unlock()
            if parar { return }
            if porDelante >= ProgramVideoConstants.audioAheadMs {
                _ = audioSpace.wait(timeout: .now() + .milliseconds(ProgramVideoConstants.readerIdleMs))
                continue
            }
            guard audioReader.status == .reading, let muestra = audioOut.copyNextSampleBuffer() else {
                lock.lock()
                audioDone = true
                lock.unlock()
                return
            }
            guard let bloque = CMSampleBufferGetDataBuffer(muestra) else { continue }
            let total = CMBlockBufferGetDataLength(bloque) / MemoryLayout<Float>.size
            let n = total / canales
            guard n > 0 else { continue }
            var intercalado = [Float](repeating: 0, count: n * canales)
            let copiado = intercalado.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(bloque, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard copiado == kCMBlockBufferNoErr else { continue }
            let primera = Int((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(muestra)) * rate).rounded())
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            let inicio = pcmStart ?? primera
            pcmStart = inicio
            // Un hueco en el fichero se rellena de silencio para que el resto siga en su sitio.
            let hueco = primera - (inicio + pcm[0].count)
            for c in 0..<canales {
                if hueco > 0 { pcm[c].append(contentsOf: repeatElement(0, count: hueco)) }
                var trozo = [Float](repeating: 0, count: n)
                for i in 0..<n { trozo[i] = intercalado[i * canales + c] }
                pcm[c].append(contentsOf: trozo)
            }
            lock.unlock()
        }
    }

    /// Y = 16 y CbCr = 128: el negro del rango de vídeo.
    private static func paintBlack(_ b: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for (plano, valor) in [(0, ProgramVideoConstants.blackLuma), (1, ProgramVideoConstants.neutralChroma)] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(b, plano) else { continue }
            memset(base, Int32(valor), CVPixelBufferGetBytesPerRowOfPlane(b, plano) * CVPixelBufferGetHeightOfPlane(b, plano))
        }
    }
}

/// El vídeo que suena en el programa, uno a la vez (ADR 0027). Lo pone `play`; el programa
/// le pide su fotograma en cada instante y el AAC su sonido por su eje. Cuando el vídeo ya
/// no tiene nada que poner, lo quita y avisa una vez con su `id`; un `stop` no avisa: quien
/// lo pidió ya lo sabe.
public final class ProgramVideoHub: ProgramAudioSubstitute {
    private let lock = NSLock()
    private var player: ProgramVideoPlayer?

    /// El vídeo `id` acabó o no pudo seguir. Se llama desde la cola de quien pidió el
    /// fotograma, fuera del cerrojo.
    public var onEnded: ((Int64) -> Void)?

    public init() {}

    /// La reproducción que suena, o nil.
    public var playingId: Int64? {
        lock.lock(); defer { lock.unlock() }
        return player?.id
    }

    /// Pone `p` en lugar del que sonara y lo echa a andar.
    public func play(_ p: ProgramVideoPlayer) {
        lock.lock()
        let viejo = player
        player = p
        lock.unlock()
        viejo?.stop()
        p.start()
    }

    public func stop() {
        lock.lock()
        let viejo = player
        player = nil
        lock.unlock()
        viejo?.stop()
    }

    /// El fotograma que tapa el programa en `t`, o nil si no suena ningún vídeo.
    public func frame(atRigMs t: Double) -> CVPixelBuffer? {
        lock.lock()
        guard let p = player else {
            lock.unlock()
            return nil
        }
        if p.isFinished(atRigMs: t) {
            player = nil
            lock.unlock()
            p.stop()
            onEnded?(p.id)
            return nil
        }
        lock.unlock()
        return p.frame(atRigMs: t)
    }

    public func samples(count: Int, atRigMs rigMs: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        lock.lock()
        let p = player
        lock.unlock()
        return p?.samples(count: count, atRigMs: rigMs, format: format)
    }
}
