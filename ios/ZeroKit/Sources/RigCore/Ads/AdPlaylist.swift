// La rotación de la franja de anuncios, lógica pura (IOS-48): réplica de cycle_ns, ad_at
// y _frame_at de tools/ad_strip.py, congelada en ad_strip.json.
//
// Todo en TIEMPO y en enteros (REF-36): la rotación puede mezclar masters de 25 y de
// 30 fps, y lo único que comparten es el reloj. Quien llama pasa los ns transcurridos
// desde que arrancó la rotación, en el reloj del soporte; aquí no se lee ningún reloj.
// Los píxeles (premultiplicado y alfa inversa) viven en RigMedia (AdStore).

import Foundation

/// Un anuncio de la rotación: su nombre (la clave de sus texturas), cuántos fotogramas
/// tiene y a qué cadencia se hizo.
public struct AdClip: Equatable, Sendable {
    public static let nsPerS: Int64 = 1_000_000_000

    public let name: String
    public let frames: Int
    public let fps: Int

    public init(name: String, frames: Int, fps: Int) {
        precondition(frames >= 1 && fps >= 1, "un anuncio tiene al menos un fotograma y una cadencia")
        self.name = name
        self.frames = frames
        self.fps = fps
    }

    /// Lo que dura UNA pasada, en ns de reloj (`Ad.duration_ns`).
    public var durationNs: Int64 { Int64(frames) * Self.nsPerS / Int64(fps) }

    /// El fotograma que toca a `localNs` de su arranque, a SU cadencia (`_frame_at`).
    public func frame(atLocalNs localNs: Int64) -> Int {
        Int((localNs * Int64(fps) / Self.nsPerS) % Int64(frames))
    }
}

/// Un anuncio con las vueltas que da antes de ceder el turno.
public struct AdSlot: Equatable, Sendable {
    public let ad: AdClip
    public let loops: Int

    public init(ad: AdClip, loops: Int = 1) throws {
        // Cero vueltas no es «no lo pongas»: es un anuncio vendido que nunca sale.
        guard loops >= 1 else {
            throw RigError.message("el slot de '\(ad.name)' tiene \(loops) vueltas; el mínimo es 1")
        }
        self.ad = ad
        self.loops = loops
    }
}

/// Un anuncio que se cuela y manda mientras dura (rotación por evento).
public struct AdOverride: Equatable, Sendable {
    public let ad: AdClip
    public let startNs: Int64
    public let loops: Int

    public init(ad: AdClip, startNs: Int64, loops: Int = 1) {
        self.ad = ad
        self.startNs = startNs
        self.loops = loops
    }

    public var durationNs: Int64 { ad.durationNs * Int64(loops) }
}

/// Lo que hay que pintar ahora.
public struct AdCue: Equatable, Sendable {
    public let ad: AdClip
    public let frame: Int

    public init(ad: AdClip, frame: Int) {
        self.ad = ad
        self.frame = frame
    }
}

public struct AdPlaylist: Equatable, Sendable {
    public let slots: [AdSlot]

    public init(slots: [AdSlot] = []) {
        self.slots = slots
    }

    /// Una vuelta completa a la rotación, en ns (`cycle_ns`).
    public var cycleNs: Int64 { slots.reduce(0) { $0 + $1.ad.durationNs * Int64($1.loops) } }

    /// Qué anuncio y qué fotograma tocan en `elapsedNs` (`ad_at`), o nil si nada.
    public func cue(atElapsedNs elapsedNs: Int64, override: AdOverride? = nil) -> AdCue? {
        let transcurrido = max(0, elapsedNs)
        if let o = override {
            let desde = transcurrido - o.startNs
            if desde >= 0, desde < o.durationNs {
                return AdCue(ad: o.ad, frame: o.ad.frame(atLocalNs: desde))
            }
        }
        let vuelta = cycleNs
        guard vuelta > 0 else { return nil }
        var posicion = transcurrido % vuelta
        for slot in slots {
            let largo = slot.ad.durationNs * Int64(slot.loops)
            if posicion < largo {
                return AdCue(ad: slot.ad, frame: slot.ad.frame(atLocalNs: posicion))
            }
            posicion -= largo
        }
        return nil  // inalcanzable: la posición se tomó módulo la suma de los largos
    }
}
