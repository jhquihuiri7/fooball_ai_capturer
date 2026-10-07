// La franja de anuncios en el maestro (IOS-48): los píxeles de cada anuncio y cuál toca.
//
// AdStore carga cada anuncio como `load_ad` (tools/ad_strip.py): fotogramas RGBA,
// deduplicados por hash, guardados YA premultiplicados más su alfa inversa, cada uno en
// una textura del alto de la franja; así el kernel ComposeProgram mezcla con una suma y
// un producto. Hay tope de memoria (`budgetBytes`): un anuncio que no cabe se rechaza al
// cargar, con un error claro, y no en mitad del partido.
//
// AdRotation junta la lista (AdPlaylist, RigCore), un override y el instante de arranque,
// y da la franja que toca en cada fotograma del programa por el reloj del soporte.

import CryptoKit
import Foundation
import ImageIO
import Metal
import RigCore

public enum AdStoreConstants {
    /// Memoria máxima de las texturas de los anuncios, en bytes. 192 MiB son ~115
    /// fotogramas distintos de 1920×108 (premultiplicado e inversa, RGBA): un anuncio fijo
    /// ocupa uno, uno animado de 10 s con mucho movimiento no cabe y hay que aligerarlo.
    /// Decisión de IOS-48 (la referencia no lo fija): anotada en PROGRESS.
    public static let budgetBytes = 192 * 1024 * 1024

    /// Cadencias admitidas (`AD_ACCEPTED_FPS`): 25 los masters del pod, 30 los del programa.
    public static let acceptedFps: Set<Int> = [25, 30]
}

public final class AdStore {
    public enum AdStoreError: Error, Equatable, CustomStringConvertible {
        case empty(String)
        case size(String)
        case opaque(String)
        case fps(String)
        case budget(String)
        case texture

        public var description: String {
            switch self {
            case let .empty(m), let .size(m), let .opaque(m), let .fps(m), let .budget(m): return m
            case .texture: return "no se pudo crear la textura del anuncio"
            }
        }
    }

    private struct Loaded {
        let clip: AdClip
        let strips: [ComposeProgramKernel.Strip]
        let index: [Int]
        let bytes: Int
    }

    private let device: MTLDevice
    public let width: Int
    public let height: Int
    public let budgetBytes: Int
    private var ads: [String: Loaded] = [:]
    private let lock = NSLock()

    public init(device: MTLDevice, width: Int, height: Int, budgetBytes: Int = AdStoreConstants.budgetBytes) {
        self.device = device
        self.width = width
        self.height = height
        self.budgetBytes = budgetBytes
    }

    public var usedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return ads.values.reduce(0) { $0 + $1.bytes }
    }

    /// Carga un anuncio de fotogramas RGBA sin premultiplicar, del tamaño de la franja.
    /// Sustituye al que tuviera el mismo nombre.
    @discardableResult
    public func load(name: String, frames: [[UInt8]], fps: Int) throws -> AdClip {
        guard AdStoreConstants.acceptedFps.contains(fps) else {
            throw AdStoreError.fps("\(name): \(fps) fps; los anuncios son a 25 o 30")
        }
        guard !frames.isEmpty else { throw AdStoreError.empty("\(name) no tiene fotogramas") }
        let tam = width * height * 4
        var vistos: [SHA256Digest: Int] = [:]
        var distintos: [[UInt8]] = []
        var indice: [Int] = []
        var algunaTransparencia = false
        for (n, f) in frames.enumerated() {
            guard f.count == tam else {
                throw AdStoreError.size("\(name): el fotograma \(n) no mide \(width)x\(height) RGBA")
            }
            let h = SHA256.hash(data: f)
            if let fila = vistos[h] {
                indice.append(fila)
                continue
            }
            vistos[h] = distintos.count
            indice.append(distintos.count)
            distintos.append(f)
            if !algunaTransparencia {
                algunaTransparencia = Swift.stride(from: 3, to: f.count, by: 4).contains { f[$0] != 255 }
            }
        }
        guard algunaTransparencia else {
            throw AdStoreError.opaque("\(name): el anuncio es opaco de punta a punta; la franja va encima de la barra y la taparía")
        }
        let bytes = distintos.count * tam * 2
        lock.lock()
        let otros = ads.filter { $0.key != name }.values.reduce(0) { $0 + $1.bytes }
        lock.unlock()
        guard otros + bytes <= budgetBytes else {
            throw AdStoreError.budget(
                "\(name): \(distintos.count) fotogramas distintos ocupan \(bytes / 1_048_576) MiB y solo quedan "
                    + "\((budgetBytes - otros) / 1_048_576): hay que aligerar el anuncio"
            )
        }
        let strips = try distintos.map { try strip(from: $0) }
        let clip = AdClip(name: name, frames: indice.count, fps: fps)
        lock.lock()
        ads[name] = Loaded(clip: clip, strips: strips, index: indice, bytes: bytes)
        lock.unlock()
        return clip
    }

    /// Carga un directorio de PNG RGBA (el master de Remotion), en orden de nombre.
    @discardableResult
    public func loadDirectory(_ url: URL, name: String, fps: Int) throws -> AdClip {
        let pngs = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !pngs.isEmpty else { throw AdStoreError.empty("\(url.path) no contiene ningún PNG") }
        return try loadFiles(pngs, name: name, fps: fps)
    }

    /// Carga un anuncio de PNG, uno por fotograma y en orden, que pueden repetirse: el
    /// paquete del VPS (IOS-49) nombra cada PNG distinto una vez y la franja repite el
    /// 90 % de los fotogramas. Cada fichero se decodifica una sola vez y los repetidos
    /// comparten el búfer, así que 600 fotogramas de 40 PNG ocupan 40 en memoria.
    @discardableResult
    public func loadFiles(_ urls: [URL], name: String, fps: Int) throws -> AdClip {
        guard !urls.isEmpty else { throw AdStoreError.empty("\(name) no tiene fotogramas") }
        var decodificados: [URL: [UInt8]] = [:]
        let frames = try urls.map { url -> [UInt8] in
            if let px = decodificados[url] { return px }
            let px = try Self.rgba(of: url)
            decodificados[url] = px
            return px
        }
        return try load(name: name, frames: frames, fps: fps)
    }

    public func clip(named name: String) -> AdClip? {
        lock.lock(); defer { lock.unlock() }
        return ads[name]?.clip
    }

    /// Las texturas del fotograma que pide la señal.
    public func strip(for cue: AdCue) -> ComposeProgramKernel.Strip? {
        lock.lock(); defer { lock.unlock() }
        guard let a = ads[cue.ad.name], !a.index.isEmpty else { return nil }
        return a.strips[a.index[cue.frame % a.index.count]]
    }

    // MARK: - Dentro

    /// Premultiplicado (redondeo de la referencia: (c·a + 127) / 255) e inversa 255 − a,
    /// RGB en r, g, b, como espera ComposeProgram.
    private func strip(from rgba: [UInt8]) throws -> ComposeProgramKernel.Strip {
        var premul = [UInt8](repeating: 0, count: rgba.count)
        var inversa = [UInt8](repeating: 0, count: rgba.count)
        for i in Swift.stride(from: 0, to: rgba.count, by: 4) {
            let a = UInt16(rgba[i + 3])
            for c in 0..<3 {
                premul[i + c] = UInt8((UInt16(rgba[i + c]) * a + 127) / 255)
                inversa[i + c] = UInt8(255 - a)
            }
            premul[i + 3] = UInt8(a)
            inversa[i + 3] = 255
        }
        return ComposeProgramKernel.Strip(premul: try texture(premul), inverse: try texture(inversa))
    }

    private func texture(_ bytes: [UInt8]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { throw AdStoreError.texture }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: width * 4)
        return t
    }

    /// RGBA de 8 bits sin premultiplicar de un PNG.
    static func rgba(of url: URL) throws -> [UInt8] {
        guard let fuente = CGImageSourceCreateWithURL(url as CFURL, nil),
              let imagen = CGImageSourceCreateImageAtIndex(fuente, 0, nil)
        else {
            throw AdStoreError.empty("\(url.lastPathComponent) no es una imagen")
        }
        let w = imagen.width, h = imagen.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // CoreGraphics solo dibuja premultiplicado: se dibuja así y se deshace después.
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AdStoreError.empty("\(url.lastPathComponent): sin contexto")
        }
        ctx.draw(imagen, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in Swift.stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 && px[i + 3] != 255 {
            let a = UInt16(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min(255, (UInt16(px[i + c]) * 255 + a / 2) / a)) }
        }
        return px
    }
}

/// La rotación en marcha: lista, override y desde cuándo, en el reloj del soporte.
public final class AdRotation {
    private let store: AdStore
    private let lock = NSLock()
    private var playlist = AdPlaylist()
    private var override: AdOverride?
    private var startRigMs: Int64 = 0

    public init(store: AdStore) {
        self.store = store
    }

    /// Una lista nueva arranca en `atRigMs`.
    public func set(playlist: AdPlaylist, atRigMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        self.playlist = playlist
        startRigMs = atRigMs
        override = nil
    }

    /// Un anuncio que se cuela desde `atRigMs` (un gol, una pausa).
    public func set(override clip: AdClip?, loops: Int = 1, atRigMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        override = clip.map { AdOverride(ad: $0, startNs: (atRigMs - startRigMs) * 1_000_000, loops: loops) }
    }

    /// Desde cuándo corre la lista y cuál es (para el informe del banco, IOS-48).
    public var started: (rigMs: Int64, playlist: AdPlaylist) {
        lock.lock(); defer { lock.unlock() }
        return (startRigMs, playlist)
    }

    /// La franja del fotograma del programa de instante `rigMs`, o nil sin anuncios.
    public func strip(atRigMs rigMs: Int64) -> (ComposeProgramKernel.Strip, AdCue)? {
        lock.lock()
        let cue = playlist.cue(atElapsedNs: (rigMs - startRigMs) * 1_000_000, override: override)
        lock.unlock()
        guard let cue, let s = store.strip(for: cue) else { return nil }
        return (s, cue)
    }
}
