// La 4K local y el reloj del soporte (IOS-57, IOS-13; medido en SPK-04 el 2026-10-11).
//
// CaptureEngine sella cada fotograma de la 4K con el reloj del soporte: el host más el
// desfase de RigClock. El escritor abre su sesión con el primer sello, y el eje de un
// .mov no admite saltos: si el desfase cambia de golpe a mitad de fichero, el contenedor
// dice durar lo que mide el salto y el codificador reparte el bitrate sobre esa duración.
// Pasó en el esclavo de la pasada de SPK-04 (`bench/dos-moviles-20261011-1506`): ~2,3 s
// en el reloj de su host, sin estimación todavía, y luego +591 898 s, la distancia entre
// los arranques de los dos iPhone. La 4K dijo durar 592 497 s y pesó el doble (7,3 GB).
//
// Esta pieza decide qué se hace con cada fotograma y cada trama de audio:
//
//   1. **Sin reloj no se abre sesión.** Un esclavo sin estimación espera, y cuenta lo que
//      tira. Si la espera pasa de RecordingPolicy.clockWaitMaxNs, graba con el reloj de
//      su host: perder la 4K entera es peor que un segmento sin emparejar.
//   2. **Un salto del desfase cierra el segmento.** Por encima de
//      RecordingPolicy.clockJumpSegmentNs entre dos fotogramas no es una corrección del
//      reloj sino otro dominio (la primera estimación, un relevo). El fotograma abre un
//      segmento nuevo, con su eje, en cuanto el reloj lo permita.
//   3. **Un sello que no avanza se tira.** Una corrección hacia atrás de más de un
//      fotograma dejaría el PTS detrás del anterior, y el escritor falla para siempre.
//   4. **El audio va con el vídeo.** Una trama con un desfase que no es el del segmento
//      abierto se tira: alargaría el fichero viejo hasta el dominio nuevo.

import Foundation

/// Lo que sabe la cámara del reloj del soporte al sellar un fotograma.
public enum RecordingClockState: Equatable, Sendable {
    /// No hay reloj del soporte que esperar: el móvil solo, o el enlace Multipeer, donde el
    /// desfase llega de Dart.
    case unlinked
    /// Este móvil es la referencia (el maestro, ADR 0023 §4): su host, o la recta que
    /// congeló al promoverse, es el reloj del soporte.
    case reference
    /// Esclavo con estimación de RigClock.
    case estimated
    /// Esclavo sin estimación todavía: su sello es el de su host, de otro dominio.
    case waiting

    /// Si con este reloj se puede abrir la sesión de un segmento.
    public var allowsSession: Bool { self != .waiting }
}

/// Qué hacer con un fotograma de la 4K.
public enum RecordingVideoDecision: Equatable, Sendable {
    /// Se tira: no hay sesión abierta y el reloj aún no vale para sellar.
    case waitForClock
    /// Abre la sesión del escritor en este fotograma y lo mete.
    case startSession
    /// Se mete en la sesión abierta.
    case append
    /// Se tira: su sello no avanza respecto al último metido.
    case outOfOrder
    /// El desfase saltó: se cierra el segmento y se abre otro. Con `startsSession`, este
    /// fotograma abre su sesión; sin él, el segmento nuevo espera al reloj.
    case rollSegment(startsSession: Bool)
}

/// La puerta del reloj de la 4K: estado de un segmento y contadores de una grabación.
public struct RecordingClockGate: Sendable {
    /// Fotogramas tirados sin sesión abierta, esperando al reloj del soporte.
    public private(set) var framesWaitingForClock: Int64 = 0
    /// Segmentos cerrados porque el desfase saltó.
    public private(set) var segmentsFromClockJump: Int64 = 0
    /// Sesiones abiertas con el reloj del host porque la espera venció.
    public private(set) var sessionsWithoutClock: Int64 = 0
    /// Fotogramas tirados porque su sello no avanzaba.
    public private(set) var framesOutOfOrder: Int64 = 0
    /// Tramas de audio tiradas porque su desfase no era el del segmento abierto.
    public private(set) var audioDroppedOnJump: Int64 = 0

    private let jumpNs: Int64
    private let waitMaxNs: Int64
    /// El desfase del último fotograma metido en el segmento; nil sin sesión abierta.
    private var segmentOffsetNs: Int64?
    /// El sello del último fotograma metido, en ns del reloj del soporte.
    private var lastRigNs: Int64?
    /// Cuándo empezó la espera al reloj, en ns del host.
    private var waitingSinceNs: Int64?

    public init(
        jumpNs: Int64 = RecordingPolicy.clockJumpSegmentNs,
        waitMaxNs: Int64 = RecordingPolicy.clockWaitMaxNs
    ) {
        self.jumpNs = jumpNs
        self.waitMaxNs = waitMaxNs
    }

    /// Si hay una sesión abierta en el segmento en curso.
    public var sessionOpen: Bool { segmentOffsetNs != nil }

    /// Quien graba abrió un segmento por su cuenta (arrancar, volver de un corte): el
    /// siguiente fotograma abre su sesión, si el reloj lo permite. Los contadores siguen.
    public mutating func segmentOpened() {
        segmentOffsetNs = nil
        lastRigNs = nil
    }

    /// Decide qué se hace con un fotograma tomado en `hostNs` (reloj del host) al que el
    /// reloj del soporte suma `offsetNs`. `clock` solo se evalúa sin sesión abierta.
    public mutating func video(
        hostNs: Int64,
        offsetNs: Int64,
        clock: @autoclosure () -> RecordingClockState
    ) -> RecordingVideoDecision {
        guard let actual = segmentOffsetNs else {
            return open(hostNs: hostNs, offsetNs: offsetNs, clock: clock()) ? .startSession : .waitForClock
        }
        if (offsetNs - actual).magnitude > jumpNs.magnitude {
            segmentsFromClockJump += 1
            segmentOpened()
            return .rollSegment(startsSession: open(hostNs: hostNs, offsetNs: offsetNs, clock: clock()))
        }
        let rigNs = hostNs + offsetNs
        if let ultimo = lastRigNs, rigNs <= ultimo {
            framesOutOfOrder += 1
            return .outOfOrder
        }
        segmentOffsetNs = offsetNs
        lastRigNs = rigNs
        return .append
    }

    /// Si una trama de audio con este desfase entra en el segmento abierto.
    public mutating func audio(offsetNs: Int64) -> Bool {
        guard let actual = segmentOffsetNs else { return false }
        if (offsetNs - actual).magnitude > jumpNs.magnitude {
            audioDroppedOnJump += 1
            return false
        }
        return true
    }

    /// Abre la sesión si el reloj vale o la espera venció; si no, cuenta el fotograma.
    private mutating func open(hostNs: Int64, offsetNs: Int64, clock: RecordingClockState) -> Bool {
        if !clock.allowsSession {
            let desde = waitingSinceNs ?? hostNs
            waitingSinceNs = desde
            guard hostNs - desde >= waitMaxNs else {
                framesWaitingForClock += 1
                return false
            }
            sessionsWithoutClock += 1
        }
        waitingSinceNs = nil
        segmentOffsetNs = offsetNs
        lastRigNs = hostNs + offsetNs
        return true
    }
}
