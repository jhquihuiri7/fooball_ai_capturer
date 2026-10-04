// El emparejador de metadatos por rigMs (IOS-32): FramePairer aplicado a lo que no
// son píxeles. Misma semántica que source/paired.py del servidor, congelada por los
// dorados de sync.json: hueco acotado por número, el más viejo que ya no puede
// emparejar sale huérfano, y con una cámara caída salen parejas incompletas en vez
// de tiempo detenido.

import Foundation

/// Cuentas del emparejado. Son diagnóstico del SOPORTE, no del software.
public struct PairingStats: Equatable, Sendable {
    public internal(set) var complete = 0
    /// Huérfanos POR LADO: si suben los dos, el soporte se desincronizó; si sube
    /// uno, esa cámara se cayó.
    public internal(set) var orphanLeft = 0
    public internal(set) var orphanRight = 0
    /// Descartados por desbordar el hueco, nunca encolados: el consumidor va más
    /// lento que la cámara.
    public internal(set) var droppedLeft = 0
    public internal(set) var droppedRight = 0
    public internal(set) var maxAbsSkewNs = 0
    /// Acumulado para la media, en crudo: un partido son 160 000 parejas y el
    /// emparejador no guarda historia.
    public internal(set) var sumAbsSkewNs = 0

    public var emitted: Int { complete + orphanLeft + orphanRight }

    public var completeness: Double {
        emitted == 0 ? 1.0 : Double(complete) / Double(emitted)
    }

    public var meanAbsSkewNs: Int {
        complete == 0 ? 0 : sumAbsSkewNs / complete
    }

    /// `false` cuando el soporte ha dejado de emparejar. Mide que HAYA parejas, no
    /// que sean buenas: las de desfase grande las corta antes la tolerancia.
    public var synchronized: Bool {
        completeness >= RigConstants.rigMinPairCompleteness
    }
}

/// Un instante del soporte con la carga de cada lado, o de uno solo si el otro faltó.
public struct PairedDetections<Payload: Sendable>: Sendable {
    public let left: (ptsNs: Int, payload: Payload)?
    public let right: (ptsNs: Int, payload: Payload)?
    /// Contador sin huecos que cuenta también los incompletos: saltarse a los
    /// huérfanos haría ver un corte de cámara como tiempo detenido.
    public let seq: Int
    /// `left - right`; 0 cuando falta un lado porque no hay nada que comparar.
    public let skewNs: Int

    public var complete: Bool { left != nil && right != nil }

    /// El instante: punto medio con las dos, que reparte el desfase y deja el error
    /// en skew/2 en vez de cargárselo entero a un lado.
    public var ptsNs: Int {
        if let left, let right {
            return (left.ptsNs + right.ptsNs) / 2
        }
        return (left ?? right)!.ptsNs
    }
}

public final class DetectionPairer<Payload: Sendable> {
    private let toleranceNs: Int
    private let bufferFrames: Int
    private var buffers: [CameraSide: [(ptsNs: Int, payload: Payload)]] = [
        .left: [], .right: [],
    ]
    private var seq = 0
    public private(set) var stats = PairingStats()

    public init(
        toleranceNs: Int = RigConstants.rigPairToleranceNs,
        bufferFrames: Int = RigConstants.rigPairBufferFrames
    ) {
        precondition(toleranceNs >= 0, "la tolerancia no puede ser negativa")
        precondition(bufferFrames >= 1, "hace falta al menos un hueco por lado")
        self.toleranceNs = toleranceNs
        self.bufferFrames = bufferFrames
    }

    public func pending(_ side: CameraSide) -> Int {
        buffers[side]!.count
    }

    /// Encola lo recién llegado de un lado. Al desbordar, descarta lo más antiguo.
    public func push(_ side: CameraSide, ptsNs: Int, payload: Payload) {
        buffers[side]!.append((ptsNs, payload))
        while buffers[side]!.count > bufferFrames {
            buffers[side]!.removeFirst()
            if side == .left { stats.droppedLeft += 1 } else { stats.droppedRight += 1 }
        }
    }

    /// El siguiente instante, o `nil` si todavía merece la pena esperar. `force`
    /// vacía lo que haya: al cerrar, lo que queda no va a encontrar pareja nunca.
    public func pop(force: Bool = false) -> PairedDetections<Payload>? {
        if let izquierda = buffers[.left]!.first, let derecha = buffers[.right]!.first {
            let skew = izquierda.ptsNs - derecha.ptsNs
            if abs(skew) <= toleranceNs {
                buffers[.left]!.removeFirst()
                buffers[.right]!.removeFirst()
                return emit(left: izquierda, right: derecha, skewNs: skew)
            }
            // El más antiguo de los dos ya no puede emparejar con nada más nuevo.
            if skew < 0 {
                buffers[.left]!.removeFirst()
                return emit(left: izquierda, right: nil, skewNs: 0)
            }
            buffers[.right]!.removeFirst()
            return emit(left: nil, right: derecha, skewNs: 0)
        }

        for side in CameraSide.allCases {
            guard let primero = buffers[side]!.first,
                  force || buffers[side]!.count >= bufferFrames
            else { continue }
            buffers[side]!.removeFirst()
            if side == .left {
                return emit(left: primero, right: nil, skewNs: 0)
            }
            return emit(left: nil, right: primero, skewNs: 0)
        }
        return nil
    }

    private func emit(
        left: (ptsNs: Int, payload: Payload)?,
        right: (ptsNs: Int, payload: Payload)?,
        skewNs: Int
    ) -> PairedDetections<Payload> {
        let pareja = PairedDetections(left: left, right: right, seq: seq, skewNs: skewNs)
        seq += 1
        if pareja.complete {
            let magnitud = abs(skewNs)
            stats.complete += 1
            stats.sumAbsSkewNs += magnitud
            stats.maxAbsSkewNs = max(stats.maxAbsSkewNs, magnitud)
        } else if left != nil {
            stats.orphanLeft += 1
        } else {
            stats.orphanRight += 1
        }
        return pareja
    }
}
