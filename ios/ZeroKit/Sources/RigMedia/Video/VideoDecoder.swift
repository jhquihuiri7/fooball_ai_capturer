// El decodificador H.264 a IOSurface para Metal (IOS-51).
//
// VTDecompressionSession con la descripción de formato sacada de los SPS/PPS EN BANDA:
// el emisor (IOS-52) los manda pegados a cada IDR, así el receptor arranca a mitad de
// partido sin más contexto que el propio stream. El destino es NV12 sobre IOSurface
// compatible con Metal: el render recorta y compone sin copiar.
//
// La cola de salida es corta a propósito (1-2 huecos): el render quiere el fotograma
// más reciente, no un búfer de latencia. Ante un error de decodificación o un hueco
// que informe el transporte, se piden IDR y se tira todo hasta que llegue: un P sin
// su referencia es papilla verde, y es peor enseñarla que congelar medio segundo.

import CoreMedia
import Foundation
import RigCore
import VideoToolbox

/// Un fotograma decodificado, con lo que traía su SEI.
public struct DecodedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let ptsNs: Int64
    public let rigMs: UInt64?
    public let viewId: UInt8?
    public let isKeyframe: Bool
}

public final class VideoDecoder {
    /// El receptor necesita un IDR: tras un hueco, un error, o antes del primer SPS.
    /// IOS-52 lo convierte en `idr_request` por control hasta que el IDR llega.
    public var onNeedsIDR: (() -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    /// Hasta el primer IDR —y tras cada hueco o error— todo lo que no sea IDR se tira.
    private var waitingForIDR = true
    private var queue: BoundedQueue<DecodedFrame>
    private let lock = NSLock()

    public private(set) var decodeFailures = 0
    /// Fotogramas tirados mientras se esperaba un IDR.
    public private(set) var droppedWaitingIDR = 0

    public init() {
        queue = BoundedQueue(capacity: VideoConstants.decodedQueueSlots, policy: .dropOldest)
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// El transporte vio un hueco de `seq`: lo que viene no tiene referencia válida.
    public func reportGap() {
        waitingForIDR = true
        onNeedsIDR?()
    }

    /// Decodifica una muestra AVCC. El fotograma aparece en `pop()` al completar.
    public func decode(avcc: Data, ptsNs: Int64) {
        let types = NalUnits.types(inAvcc: avcc)
        if types.contains(7), types.contains(8) {
            adoptParameterSets(from: avcc)
        }
        let isIDR = types.contains(5)

        if waitingForIDR, !isIDR {
            droppedWaitingIDR += 1
            onNeedsIDR?()
            return
        }
        guard let session, let format else {
            // Un IDR sin SPS/PPS a la vista no se puede abrir: se insiste.
            droppedWaitingIDR += 1
            onNeedsIDR?()
            return
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            decodeFailures += 1
            return
        }
        _ = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count
            )
        }
        var sampleBuffer: CMSampleBuffer?
        var tamano = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &tamano,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            decodeFailures += 1
            return
        }

        let sei = H264Sei.find(inAvcc: avcc)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imagen, _, _ in
            guard let self else { return }
            guard status == noErr, let imagen = imagen as CVPixelBuffer? else {
                self.decodeFailures += 1
                self.waitingForIDR = true
                self.onNeedsIDR?()
                return
            }
            let frame = DecodedFrame(
                pixelBuffer: imagen, ptsNs: ptsNs,
                rigMs: sei?.rigMs, viewId: sei?.viewId, isKeyframe: isIDR
            )
            self.lock.lock()
            self.queue.push(frame)
            self.lock.unlock()
        }
        if status == noErr {
            if isIDR {
                waitingForIDR = false
            }
        } else {
            decodeFailures += 1
            waitingForIDR = true
            onNeedsIDR?()
        }
    }

    /// El fotograma decodificado más viejo que espera, o `nil`.
    public func pop() -> DecodedFrame? {
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

    // MARK: - SPS/PPS en banda

    private func adoptParameterSets(from avcc: Data) {
        var sps: Data?
        var pps: Data?
        NalUnits.forEachNal(inAvcc: avcc) { nal in
            guard let primero = nal.first else { return }
            switch primero & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }
        guard let sps, let pps else { return }

        var creado: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: [
                        spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ],
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &creado
                )
            }
        }
        guard status == noErr, let nuevo = creado else { return }
        if let actual = format, CMFormatDescriptionEqual(actual, otherFormatDescription: nuevo) {
            return
        }
        format = nuevo
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        // NV12 lineal sobre IOSurface y compatible con Metal: lo que el render pide.
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var creada: VTDecompressionSession?
        let creacion = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: nuevo, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &creada
        )
        if creacion == noErr, let creada {
            VTSessionSetProperty(creada, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            session = creada
        }
    }
}

/// Los SPS/PPS de una descripción de formato, como NALs AVCC listas para pegar
/// delante de un IDR: es lo que el emisor manda «en banda» (IOS-52).
public enum H264ParameterSets {
    public static func avccNals(from format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else {
                continue
            }
            out.appendBigEndian(UInt32(size))
            out.append(Data(bytes: pointer, count: size))
        }
        return out
    }
}
