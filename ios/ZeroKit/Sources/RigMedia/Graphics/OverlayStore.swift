// El gráfico del programa, de Dart a Metal (IOS-47).
//
// Dart rasteriza cada capa (marcador, alineación, SIN SEÑAL) cuando cambia y manda SOLO
// el rectángulo que cambió respecto a lo último que mandó (un parche): con el reloj en
// marcha, las cifras del reloj. Aquí:
// - cada capa es un búfer RGBA a tamaño de programa, reservado la primera vez que se usa,
//   donde se pega cada parche;
// - un búfer RGBA a tamaño de programa, preasignado, tiene las capas ya apiladas (alfa
//   SIN premultiplicar, «over» de abajo arriba: SIN SEÑAL, marcador, alineación); un
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

    /// De abajo arriba: SIN SEÑAL debajo del marcador (sale «con el marcador», IOS-84) y
    /// la alineación encima de todo (tapa el marcador, como en el panel). Los números
    /// crudos son los de Pigeon, no el orden.
    public static let stackOrder: [OverlayLayer] = [.slate, .scoreboard, .lineup]
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
        /// Dónde ha habido algo desde el último borrado: lo que hay que limpiar al quitarla.
        var bounds: Rect
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
    /// Las capas ocultas (están cargadas pero no se componen). SIN SEÑAL empieza oculta:
    /// Dart la sube al empezar y la enseña el programa cuando no queda cámara (IOS-84).
    private var hidden: Set<OverlayLayer> = [.slate]
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

    /// Pega un parche en una capa: RGBA sin premultiplicar de `rect.width × rect.height` en
    /// `rect` del programa (sustituye esos píxeles, transparentes incluidos). Una generación
    /// que no sube se ignora (llegó tarde). Asíncrono.
    public func set(_ layer: OverlayLayer, rgba: [UInt8], rect: Rect, generation: Int,
                    completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            let r = rect.clipped(width: width, height: height)
            guard rgba.count == rect.width * rect.height * 4, !r.isEmpty else { return }
            lock.lock()
            var capa = layers[layer] ?? Layer(
                rgba: [UInt8](repeating: 0, count: width * height * 4), bounds: .empty, generation: 0
            )
            guard generation > capa.generation else {
                lock.unlock()
                return
            }
            for y in r.y..<(r.y + r.height) {
                let desde = ((y - rect.y) * rect.width + (r.x - rect.x)) * 4
                let hacia = (y * width + r.x) * 4
                capa.rgba.replaceSubrange(hacia..<(hacia + r.width * 4), with: rgba[desde..<(desde + r.width * 4)])
            }
            capa.bounds = capa.bounds.union(r)
            capa.generation = generation
            layers[layer] = capa
            lock.unlock()
            apply(dirty: r)
        }
    }

    /// Quita una capa. Asíncrono.
    public func clear(_ layer: OverlayLayer, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            lock.lock()
            let vieja = layers.removeValue(forKey: layer)
            lock.unlock()
            if let vieja { apply(dirty: vieja.bounds) }
        }
    }

    /// Enseña u oculta una capa ya cargada. Asíncrono.
    public func setVisible(_ layer: OverlayLayer, _ visible: Bool, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            lock.lock()
            let cambia = visible == hidden.contains(layer)
            if visible { hidden.remove(layer) } else { hidden.insert(layer) }
            let caja = layers[layer]?.bounds
            lock.unlock()
            if cambia, let caja { apply(dirty: caja) }
        }
    }

    /// La textura activa para este fotograma; nil si no hay gráfico. Hay que soltarla
    /// con `endFrame` cuando el command buffer haya terminado.
    public func beginFrame() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard layers.keys.contains(where: { !hidden.contains($0) }) else { return nil }
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
        let pila = OverlayLayer.stackOrder.filter { !hidden.contains($0) }.compactMap { layers[$0] }
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

    /// Apila las capas en el búfer de CPU dentro de `r`: «over» con alfa sin premultiplicar,
    /// en enteros (×255) para no pasar por coma flotante en cada píxel.
    private func recompose(_ r: Rect, _ pila: [Layer]) {
        guard !r.isEmpty else { return }
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let o = (y * width + x) * 4
                // Color premultiplicado y alfa, los dos en escala 0…255·255.
                var pr = 0, pg = 0, pb = 0, pa = 0
                for capa in pila {
                    let a = Int(capa.rgba[o + 3])
                    guard a > 0 else { continue }
                    let resto = 255 - a
                    pr = Int(capa.rgba[o]) * a + pr * resto / 255
                    pg = Int(capa.rgba[o + 1]) * a + pg * resto / 255
                    pb = Int(capa.rgba[o + 2]) * a + pb * resto / 255
                    pa = a * 255 + pa * resto / 255
                }
                if pa > 0 {
                    composite[o] = UInt8(min(255, (pr * 255 + pa / 2) / pa))
                    composite[o + 1] = UInt8(min(255, (pg * 255 + pa / 2) / pa))
                    composite[o + 2] = UInt8(min(255, (pb * 255 + pa / 2) / pa))
                    composite[o + 3] = UInt8(min(255, (pa + 127) / 255))
                } else {
                    composite[o] = 0; composite[o + 1] = 0; composite[o + 2] = 0; composite[o + 3] = 0
                }
            }
        }
    }
}
