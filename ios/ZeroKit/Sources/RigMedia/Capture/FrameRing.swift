// El anillo de fotogramas propio (IOS-04): K fotogramas NV12 indexados por rigMs.
//
// La cámara retiene como mucho UN búfer suyo (IOS-09): lo que el pipeline necesite
// después —el detector a 7,5 Hz, el render, la vista previa— se copia aquí, a búferes
// propios preasignados. El anillo nunca espera y nunca reserva: si todos los huecos
// están referenciados, el fotograma se descarta y se cuenta, que es la política de
// colas del servidor.
//
// `acquire` devuelve el fotograma con el rigMs más cercano y lo deja referenciado: un
// hueco referenciado no se reutiliza, así que un fotograma entregado nunca se
// sobrescribe por debajo. La pareja (hueco, generación) hace imposible liberar tarde
// sobre un ocupante nuevo.

import CoreVideo
import Foundation

public final class FrameRing {
    /// Un fotograma entregado. Se devuelve con `release(_:)`; soltarlo tarde no puede
    /// tocar a otro ocupante porque la generación ya no cuadra.
    public struct Lease {
        public let buffer: CVPixelBuffer
        public let rigMs: Int64
        fileprivate let slot: Int
        fileprivate let generation: UInt64
    }

    private struct Slot {
        var buffer: CVPixelBuffer
        var rigMs: Int64 = -1
        var generation: UInt64 = 0
        var references = 0
        var occupied = false
    }

    private let lock = NSLock()
    private var slots: [Slot]

    /// Descartes por anillo lleno (todos los huecos referenciados). Telemetría.
    public private(set) var dropped = 0

    /// El tamaño de los fotogramas del anillo, en píxeles.
    public let width: Int
    public let height: Int

    public init?(
        slots count: Int = PipelineConstants.frameRingSlots,
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) {
        self.width = width
        self.height = height
        guard count > 0,
              let pool = PixelBufferPool(
                  width: width, height: height, pixelFormat: pixelFormat, capacity: count
              )
        else {
            return nil
        }
        var preparados: [Slot] = []
        for _ in 0..<count {
            guard let buffer = pool.take() else { return nil }
            preparados.append(Slot(buffer: buffer))
        }
        slots = preparados
    }

    /// Copia un fotograma al anillo: elige el hueco libre más viejo, deja que `fill`
    /// lo rellene (un blit, nunca un proceso largo) y lo indexa por su rigMs.
    /// Devuelve `false` —y cuenta el descarte— si todos los huecos están referenciados.
    @discardableResult
    public func store(rigMs: Int64, fill: (CVPixelBuffer) -> Void) -> Bool {
        lock.lock()
        var victima = -1
        var masViejo = Int64.max
        for (indice, slot) in slots.enumerated() where slot.references == 0 {
            let edad = slot.occupied ? slot.rigMs : Int64.min
            if edad < masViejo {
                masViejo = edad
                victima = indice
            }
        }
        guard victima >= 0 else {
            dropped += 1
            lock.unlock()
            return false
        }
        // El hueco queda referenciado mientras se rellena: nadie lo puede adquirir a
        // medio escribir, y otro store no lo puede elegir de víctima. La generación
        // sube AQUÍ, al reclamar: así una liberación tardía de la generación anterior
        // ya no cuadra y no puede soltar el hueco a mitad del fill.
        slots[victima].references = 1
        slots[victima].occupied = false
        slots[victima].generation &+= 1
        let buffer = slots[victima].buffer
        lock.unlock()

        fill(buffer)

        lock.lock()
        slots[victima].rigMs = rigMs
        slots[victima].references = 0
        slots[victima].occupied = true
        lock.unlock()
        return true
    }

    /// El fotograma con el rigMs más cercano al pedido, referenciado, o `nil` si el
    /// anillo está vacío. `maxDistanceMs` descarta un «más cercano» que ya no vale.
    public func acquire(nearest rigMs: Int64, maxDistanceMs: Int64 = .max) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        var mejor = -1
        var distancia = Int64.max
        for (indice, slot) in slots.enumerated() where slot.occupied {
            let actual = abs(slot.rigMs - rigMs)
            if actual < distancia {
                distancia = actual
                mejor = indice
            }
        }
        guard mejor >= 0, distancia <= maxDistanceMs else { return nil }
        slots[mejor].references += 1
        return Lease(
            buffer: slots[mejor].buffer,
            rigMs: slots[mejor].rigMs,
            slot: mejor,
            generation: slots[mejor].generation
        )
    }

    /// Devuelve un fotograma. Un lease de una generación vieja se ignora: su hueco ya
    /// es de otro y no hay nada que soltar.
    public func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[lease.slot].generation == lease.generation,
              slots[lease.slot].references > 0
        else {
            return
        }
        slots[lease.slot].references -= 1
    }
}
