// El volcado NV12 crudo para medir el salto de dominio (IOS-15).
//
// Cada N segundos se guarda el fotograma tal como está ANTES del codificador: es la
// referencia contra la que ML-18 mide cuánto estropea el HEVC (el «salto de dominio»
// entre lo que ve el detector en vivo y lo que se reprocesa en diferido).
//
// El formato del fichero, acordado con ML-18 (football-ai-training):
//
//   [4 bytes BE: longitud de la cabecera] [cabecera JSON UTF-8] [plano Y] [plano CbCr]
//
// Los planos van sin el relleno del stride: ancho × alto y ancho × alto/2 bytes. La
// cabecera lleva rig_ms, side, width, height, pixel_format (el FourCC) y color
// (matriz, primarias, transferencia), que es lo que hace falta para reconstruir el
// color exacto al comparar.
//
// La copia de los planos es síncrona (quien llama tiene el búfer vivo); la escritura
// a disco va en una cola propia para no robarle milisegundos al hilo de la cámara.

import CoreVideo
import Foundation
import RigCore

public final class Nv12Dumper {
    /// Intervalo por defecto entre volcados, en segundos. Uno por minuto deja ~30
    /// referencias por partido de prueba: de sobra para medir y poco para el disco
    /// (12,4 MB cada una en 4K).
    public static let defaultIntervalS = 60.0

    private let directory: URL
    private let side: String
    private let intervalMs: UInt64
    private let queue = DispatchQueue(label: "io.footballai.nv12-dump", qos: .utility)
    private var lastDumpMs: UInt64?
    /// Volcados escritos y fallos de escritura, para el informe del banco.
    public private(set) var written = 0
    public private(set) var failures = 0
    private let lock = NSLock()

    public init(directory: URL, side: String, intervalS: Double = Nv12Dumper.defaultIntervalS) {
        self.directory = directory
        self.side = side
        intervalMs = UInt64(max(intervalS, 1.0) * 1000)
    }

    /// Vuelca si ya toca. Copia los planos aquí mismo —el búfer es de quien llama— y
    /// escribe en su cola. Devuelve si este fotograma se volcó.
    @discardableResult
    public func maybeDump(_ pixelBuffer: CVPixelBuffer, rigMs: UInt64) -> Bool {
        lock.lock()
        if let last = lastDumpMs, rigMs &- last < intervalMs {
            lock.unlock()
            return false
        }
        lastDumpMs = rigMs
        lock.unlock()

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var payload = Data(capacity: width * height * 3 / 2)
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                return false
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)  // CbCr entrelazado: 2 bytes por muestra
            if stride == rowBytes {
                payload.append(Data(bytes: base, count: rowBytes * rows))
            } else {
                for row in 0..<rows {
                    payload.append(Data(bytes: base + row * stride, count: rowBytes))
                }
            }
        }

        let header = Self.header(for: pixelBuffer, rigMs: rigMs, side: side)
        let destino = directory.appendingPathComponent("\(side)-\(rigMs).nv12")
        queue.async { [weak self] in
            self?.write(header: header, payload: payload, to: destino)
        }
        return true
    }

    /// La cabecera JSON, con claves ordenadas para que ML-18 tenga bytes estables.
    static func header(for pixelBuffer: CVPixelBuffer, rigMs: UInt64, side: String) -> Data {
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourcc = String(
            format: "%c%c%c%c",
            (format >> 24) & 255, (format >> 16) & 255, (format >> 8) & 255, format & 255
        )
        let doc: [String: Any] = [
            "schema": 1,
            "rig_ms": rigMs,
            "side": side,
            "width": CVPixelBufferGetWidth(pixelBuffer),
            "height": CVPixelBufferGetHeight(pixelBuffer),
            "pixel_format": fourcc,
            "color": [
                "matrix": attachment(kCVImageBufferYCbCrMatrixKey) ?? "",
                "primaries": attachment(kCVImageBufferColorPrimariesKey) ?? "",
                "transfer": attachment(kCVImageBufferTransferFunctionKey) ?? "",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
    }

    private func write(header: Data, payload: Data, to destino: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            var out = Data(capacity: 4 + header.count + payload.count)
            out.appendBigEndian(UInt32(header.count))
            out.append(header)
            out.append(payload)
            try out.write(to: destino, options: .atomic)
            lock.lock()
            written += 1
            lock.unlock()
        } catch {
            lock.lock()
            failures += 1
            lock.unlock()
        }
    }

    /// Espera a que lo encolado esté en disco (para los tests y el fin del banco).
    public func drain() {
        queue.sync {}
    }
}
