// Los fotogramas de calibración de un móvil (IOS-70).
//
// Para cada instante de destino que mandó el maestro, espera a que el anillo tenga un
// fotograma a su altura, elige el que toca (CalibrationPlan.choose: el más cercano a
// ≤16 ms, si no el siguiente), lo fija mientras lo codifica y lo guarda en JPEG q95 4K
// con un JSON al lado: lado, instante, destino, intrínsecas de ESE fotograma, tamaño, si
// el móvil va girado y lo que el llamante añada (modelo, iOS, exposición y balance).
// Los ficheros van a `directory`, que IOS-71 sube al servicio de calibración.

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import RigCore
import UniformTypeIdentifiers

public final class CalibrationStillCapture {
    public struct Still: Equatable, Sendable {
        public let targetRigMs: Int64
        public let rigMs: Int64
        public let jpeg: URL
        public let json: URL
        public let bytes: Int
        public let hasIntrinsics: Bool

        public var deltaMs: Int64 { rigMs - targetRigMs }
    }

    public enum CaptureError: Error, Equatable, CustomStringConvertible {
        case timeout(target: Int64)
        case lost(target: Int64)
        case encode(String)
        case tooBig(bytes: Int)

        public var description: String {
            switch self {
            case let .timeout(t): return "no llegó ningún fotograma para el destino \(t)"
            case let .lost(t): return "el fotograma del destino \(t) salió del anillo antes de fijarlo"
            case let .encode(m): return "no se pudo codificar el JPEG: \(m)"
            case let .tooBig(b): return "el JPEG ocupa \(b) bytes, más que RIG_CALIB_JPEG_MAX_BYTES"
            }
        }
    }

    /// Cada cuánto se mira el anillo mientras se espera un destino, en ms.
    static let pollMs = 5
    /// Lo más que se espera un destino después de su hora, en ms: un segundo es que la
    /// cámara está parada.
    static let maxWaitMs: Int64 = 1000

    private let side: CameraSide
    private let ring: FrameRing
    private let intrinsics: (Int64) -> [Float]?
    private let mountedUpsideDown: Bool
    private let directory: URL
    private let extraMeta: () -> [String: Any]
    private let queue = DispatchQueue(label: "io.footballai.zero.calib", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init(
        side: CameraSide,
        ring: FrameRing,
        intrinsics: @escaping (Int64) -> [Float]?,
        mountedUpsideDown: Bool,
        directory: URL,
        extraMeta: @escaping () -> [String: Any] = { [:] }
    ) {
        self.side = side
        self.ring = ring
        self.intrinsics = intrinsics
        self.mountedUpsideDown = mountedUpsideDown
        self.directory = directory
        self.extraMeta = extraMeta
    }

    /// Captura un fotograma por destino, en orden, y llama a `completion` con todos o con
    /// el primer error. `nowRigMs` es el reloj del soporte de este móvil.
    public func capture(
        targets: [Int64],
        nowRigMs: @escaping () -> Int64,
        completion: @escaping (Result<[Still], CaptureError>) -> Void
    ) {
        queue.async { [self] in
            var hechas: [Still] = []
            for destino in targets {
                switch captureOne(target: destino, nowRigMs: nowRigMs) {
                case let .success(s):
                    hechas.append(s)
                case let .failure(e):
                    completion(.failure(e))
                    return
                }
            }
            completion(.success(hechas))
        }
    }

    private func captureOne(target: Int64, nowRigMs: () -> Int64) -> Result<Still, CaptureError> {
        // Se decide cuando ya ha llegado un fotograma a la altura del destino: entonces el
        // más cercano de antes y el primero de después están los dos a la vista.
        var elegido: Int64?
        while elegido == nil {
            let hay = ring.availableRigMs()
            if let ultimo = hay.last, ultimo >= target {
                elegido = CalibrationPlan.choose(available: hay, target: target)
            } else if nowRigMs() > target + Self.maxWaitMs {
                return .failure(.timeout(target: target))
            } else {
                Thread.sleep(forTimeInterval: Double(Self.pollMs) / 1000)
            }
        }
        guard let rigMs = elegido, let lease = ring.acquire(nearest: rigMs, maxDistanceMs: 0) else {
            return .failure(.lost(target: target))
        }
        defer { ring.release(lease) }
        return write(lease.buffer, rigMs: rigMs, target: target)
    }

    /// El JPEG y su JSON. Público para el test, que no tiene cámara.
    func write(_ buffer: CVPixelBuffer, rigMs: Int64, target: Int64) -> Result<Still, CaptureError> {
        let nombre = "\(side.rawValue)-\(rigMs)"
        let jpeg = directory.appendingPathComponent("\(nombre).jpg")
        let json = directory.appendingPathComponent("\(nombre).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.encode("\(error)"))
        }
        let imagen = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(imagen, from: imagen.extent),
              let destino = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return .failure(.encode("sin CGImage o sin destino"))
        }
        CGImageDestinationAddImage(destino, cg, [
            kCGImageDestinationLossyCompressionQuality: RigConstants.rigCalibJpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destino) else {
            return .failure(.encode("CGImageDestinationFinalize"))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: jpeg.path)[.size] as? Int) ?? 0
        guard bytes <= RigConstants.rigCalibJpegMaxBytes else {
            return .failure(.tooBig(bytes: bytes))
        }
        let k = intrinsics(rigMs)
        var meta: [String: Any] = [
            "schema": 1,
            "side": side.rawValue,
            "rig_ms": rigMs,
            "target_rig_ms": target,
            "width": CVPixelBufferGetWidth(buffer),
            "height": CVPixelBufferGetHeight(buffer),
            "mount_flip": mountedUpsideDown,
            "jpeg_quality": RigConstants.rigCalibJpegQuality,
        ]
        if let k { meta["intrinsics"] = k.map(Double.init) }
        meta.merge(extraMeta()) { propio, _ in propio }
        do {
            let datos = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .prettyPrinted])
            try datos.write(to: json, options: .atomic)
        } catch {
            return .failure(.encode("\(error)"))
        }
        return .success(Still(
            targetRigMs: target, rigMs: rigMs, jpeg: jpeg, json: json, bytes: bytes, hasIntrinsics: k != nil
        ))
    }
}
