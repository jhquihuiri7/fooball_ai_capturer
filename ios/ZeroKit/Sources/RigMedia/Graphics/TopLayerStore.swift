// La capa de encima del programa (IOS-118, ADR 0034): la cortinilla y el rótulo de la
// repetición, de Dart a Metal.
//
// Como el gráfico (OverlayStore), Dart manda solo el rectángulo que cambió y aquí se pega en
// una copia a tamaño de programa, que se sube a dos texturas que se turnan. Pero es una sola
// capa: no hay que apilar nada en CPU, y un parche se copia por filas. Una cortinilla cambia
// casi la pantalla entera en cada fotograma, a 20 fps, y el apilado píxel a píxel del gráfico
// no da para eso. El kernel la mezcla encima de todo, también de la franja.
//
// En el bucle de fotogramas no se reserva nada: la copia y las dos texturas se reservan al
// crearla.

import Foundation
import Metal

public final class TopLayerStore {
    /// El número de la capa en `setOverlay` de Pigeon (0 marcador, 1 alineación, 2 SIN SEÑAL).
    public static let layerId = 3

    public let width: Int
    public let height: Int
    private let textures: [MTLTexture]
    /// La capa en CPU, RGBA sin premultiplicar. Solo la toca la cola propia.
    private var pixels: [UInt8]
    private let queue = DispatchQueue(label: "io.footballai.zero.toplayer", qos: .userInitiated)

    // Con `lock`.
    private let lock = NSLock()
    private var active = 0
    private var inUse = false
    /// Dónde hay algo pintado: lo que hay que limpiar al quitarla.
    private var bounds = OverlayStore.Rect.empty
    private var generation = 0
    /// Lo que la textura de atrás aún no tiene de los cambios anteriores. Solo en la cola.
    private var pendingForBack = OverlayStore.Rect.empty

    /// Cambios aplicados, y cuánto tardó el último en subir (ms), para el banco.
    public private(set) var uploads = 0
    public private(set) var lastUploadMs = 0.0

    public init?(device: MTLDevice, width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let a = device.makeTexture(descriptor: d), let b = device.makeTexture(descriptor: d) else {
            return nil
        }
        self.width = width
        self.height = height
        textures = [a, b]
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for t in textures {
            pixels.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
        }
    }

    /// Hay algo en la capa: si no, el kernel no la lee.
    public var hasContent: Bool {
        lock.lock(); defer { lock.unlock() }
        return !bounds.isEmpty
    }

    /// Pega un parche: RGBA sin premultiplicar de `rect.width × rect.height` en `rect` del
    /// programa (sustituye esos píxeles, transparentes incluidos). Una generación que no sube
    /// se ignora (llegó tarde). Asíncrono.
    public func set(rgba: [UInt8], rect: OverlayStore.Rect, generation: Int, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            let r = rect.clipped(width: width, height: height)
            guard rgba.count == rect.width * rect.height * 4, !r.isEmpty else { return }
            lock.lock()
            guard generation > self.generation else {
                lock.unlock()
                return
            }
            self.generation = generation
            lock.unlock()
            let ancho = width
            rgba.withUnsafeBufferPointer { origen in
                pixels.withUnsafeMutableBufferPointer { destino in
                    for y in r.y..<(r.y + r.height) {
                        let desde = ((y - rect.y) * rect.width + (r.x - rect.x)) * 4
                        let hacia = (y * ancho + r.x) * 4
                        (destino.baseAddress! + hacia).update(from: origen.baseAddress! + desde, count: r.width * 4)
                    }
                }
            }
            lock.lock()
            bounds = bounds.union(r)
            lock.unlock()
            upload(dirty: r)
        }
    }

    /// La deja vacía. Asíncrono.
    public func clear(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            lock.lock()
            let vieja = bounds
            bounds = .empty
            // Como al quitar una capa del gráfico: lo siguiente puede empezar de nuevo por la
            // generación 1 (otro maestro, la app de Dart reiniciada).
            generation = 0
            lock.unlock()
            guard !vieja.isEmpty else { return }
            let ancho = width
            pixels.withUnsafeMutableBufferPointer { destino in
                for y in vieja.y..<(vieja.y + vieja.height) {
                    (destino.baseAddress! + (y * ancho + vieja.x) * 4).update(repeating: 0, count: vieja.width * 4)
                }
            }
            upload(dirty: vieja)
        }
    }

    /// La textura activa para este fotograma; nil si la capa está vacía. Hay que soltarla con
    /// `endFrame` cuando el command buffer haya terminado.
    public func beginFrame() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard !bounds.isEmpty else { return nil }
        inUse = true
        return textures[active]
    }

    public func endFrame() {
        lock.lock(); inUse = false; lock.unlock()
    }

    // MARK: - Dentro (en la cola propia)

    /// Sube a la textura de atrás lo sucio y lo que le faltaba, y la cambia por la activa en
    /// cuanto nadie la esté leyendo.
    private func upload(dirty bruto: OverlayStore.Rect) {
        let inicio = DispatchTime.now().uptimeNanoseconds
        let dirty = bruto.clipped(width: width, height: height)
        let subir = dirty.union(pendingForBack).clipped(width: width, height: height)
        lock.lock()
        let atras = 1 - active
        lock.unlock()
        if !subir.isEmpty {
            pixels.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: (subir.y * width + subir.x) * 4)
                textures[atras].replace(
                    region: MTLRegionMake2D(subir.x, subir.y, subir.width, subir.height),
                    mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4
                )
            }
        }
        while true {
            lock.lock()
            if !inUse {
                active = atras
                uploads += 1
                lastUploadMs = Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6
                lock.unlock()
                pendingForBack = dirty
                return
            }
            lock.unlock()
            usleep(500)
        }
    }
}
