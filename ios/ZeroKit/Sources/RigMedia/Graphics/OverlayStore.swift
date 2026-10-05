// El gráfico del programa, de Dart a Metal (IOS-47).
//
// Dart rasteriza cada capa (marcador, alineación, SIN SEÑAL) cuando cambia, la recorta a
// la caja con contenido y la manda con su posición. Aquí:
// - cada capa se guarda en CPU con su caja;
// - un búfer RGBA a tamaño de programa, preasignado, tiene las capas ya apiladas (alfa
//   SIN premultiplicar, «over» de abajo arriba: marcador, alineación, SIN SEÑAL); un
//   cambio solo recompone el rectángulo sucio (la caja vieja y la nueva);
// - dos texturas a tamaño de programa, preasignadas: se sube a la de atrás lo sucio
//   (más lo que le faltaba de la vez anterior) y se cambia de golpe. Quien compone toma
//   la activa con `beginFrame` y la suelta con `endFrame`; mientras la usa, nadie la
//   escribe. En el bucle de fotogramas no se reserva nada.

import Foundation
import Metal
import RigCore

public enum OverlayLayer: Int, CaseIterable, Sendable {
    case scoreboard = 0
    case lineup = 1
    case slate = 2
}

public final class OverlayStore {
    public struct Rect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        var isEmpty: Bool { width <= 0 || height <= 0 }

        func union(_ o: Rect) -> Rect {
            if isEmpty { return o }
            if o.isEmpty { return self }
            let x0 = min(x, o.x), y0 = min(y, o.y)
            let x1 = max(x + width, o.x + o.width), y1 = max(y + height, o.y + o.height)
            return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        func clipped(width w: Int, height h: Int) -> Rect {
            let x0 = max(0, x), y0 = max(0, y)
            let x1 = min(w, x + width), y1 = min(h, y + height)
            return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        }

        static let empty = Rect(x: 0, y: 0, width: 0, height: 0)
    }

    private struct Layer {
        var rgba: [UInt8]
        var rect: Rect
        var generation: Int
    }

    public let width: Int
    public let height: Int
    private let textures: [MTLTexture]
    private var active = 0
    private var inUse = false
    /// Lo que la textura de atrás aún no tiene de los cambios anteriores.
    private var pendingForBack = Rect.empty
    private var layers: [OverlayLayer: Layer] = [:]
    private var composite: [UInt8]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.footballai.zero.overlay", qos: .userInitiated)

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
        composite = [UInt8](repeating: 0, count: width * height * 4)
        let ceros = [UInt8](repeating: 0, count: width * height * 4)
        for t in textures {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: ceros, bytesPerRow: width * 4)
        }
    }

    /// Hay alguna capa a la vista: si no, la composición no lee gráfico.
    public var hasContent: Bool {
        lock.lock(); defer { lock.unlock() }
        return !layers.isEmpty
    }

    /// Pone (o cambia) una capa: RGBA sin premultiplicar de `rect.width × rect.height` en
    /// `rect`. Una generación que no sube se ignora (llegó tarde). Asíncrono.
    public func set(_ layer: OverlayLayer, rgba: [UInt8], rect: Rect, generation: Int,
                    completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            guard rgba.count == rect.width * rect.height * 4 else { return }
            lock.lock()
            let vieja = layers[layer]
            if let vieja, generation <= vieja.generation {
                lock.unlock()
                return
            }
            layers[layer] = Layer(rgba: rgba, rect: rect, generation: generation)
            lock.unlock()
            apply(dirty: rect.union(vieja?.rect ?? .empty))
        }
    }

    /// Quita una capa. Asíncrono.
    public func clear(_ layer: OverlayLayer, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            lock.lock()
            let vieja = layers.removeValue(forKey: layer)
            lock.unlock()
            if let vieja { apply(dirty: vieja.rect) }
        }
    }

    /// La textura activa para este fotograma; nil si no hay gráfico. Hay que soltarla
    /// con `endFrame` cuando el command buffer haya terminado.
    public func beginFrame() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard !layers.isEmpty else { return nil }
        inUse = true
        return textures[active]
    }

    public func endFrame() {
        lock.lock(); inUse = false; lock.unlock()
    }

    // MARK: - Dentro (en la cola propia)

    private func apply(dirty bruto: Rect) {
        let inicio = DispatchTime.now().uptimeNanoseconds
        let dirty = bruto.clipped(width: width, height: height)
        lock.lock()
        let pila = OverlayLayer.allCases.compactMap { layers[$0] }
        lock.unlock()
        recompose(dirty, pila)

        // La de atrás recibe lo sucio y lo que le faltaba; luego se cambia.
        let subir = dirty.union(pendingForBack).clipped(width: width, height: height)
        lock.lock()
        let atras = 1 - active
        lock.unlock()
        if !subir.isEmpty {
            composite.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: (subir.y * width + subir.x) * 4)
                textures[atras].replace(
                    region: MTLRegionMake2D(subir.x, subir.y, subir.width, subir.height),
                    mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4
                )
            }
        }
        // La activa está en uso por un fotograma: se espera a que acabe para cambiar,
        // así la siguiente escritura (a la que ahora es activa) no pisa una lectura.
        while true {
            lock.lock()
            if !inUse {
                active = atras
                pendingForBack = dirty
                uploads += 1
                lastUploadMs = Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6
                lock.unlock()
                return
            }
            lock.unlock()
            usleep(500)
        }
    }

    /// Apila las capas en el búfer de CPU dentro de `r`: «over» con alfa sin premultiplicar.
    private func recompose(_ r: Rect, _ pila: [Layer]) {
        guard !r.isEmpty else { return }
        for y in r.y..<(r.y + r.height) {
            let fila = y * width * 4
            for x in r.x..<(r.x + r.width) {
                var cr = 0.0, cg = 0.0, cb = 0.0, ca = 0.0  // premultiplicado durante la mezcla
                for capa in pila {
                    let lx = x - capa.rect.x, ly = y - capa.rect.y
                    guard lx >= 0, ly >= 0, lx < capa.rect.width, ly < capa.rect.height else { continue }
                    let i = (ly * capa.rect.width + lx) * 4
                    let a = Double(capa.rgba[i + 3]) / 255
                    guard a > 0 else { continue }
                    cr = Double(capa.rgba[i]) * a + cr * (1 - a)
                    cg = Double(capa.rgba[i + 1]) * a + cg * (1 - a)
                    cb = Double(capa.rgba[i + 2]) * a + cb * (1 - a)
                    ca = a + ca * (1 - a)
                }
                let o = fila + x * 4
                if ca > 0 {
                    composite[o] = UInt8((cr / ca).rounded())
                    composite[o + 1] = UInt8((cg / ca).rounded())
                    composite[o + 2] = UInt8((cb / ca).rounded())
                    composite[o + 3] = UInt8((ca * 255).rounded())
                } else {
                    composite[o] = 0; composite[o + 1] = 0; composite[o + 2] = 0; composite[o + 3] = 0
                }
            }
        }
    }
}
