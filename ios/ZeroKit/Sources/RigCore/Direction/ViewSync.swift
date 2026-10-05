// La sincronía de vistas y partes entre los dos móviles (IOS-42, ADR 0023 §5), lógica
// pura.
//
// El director del maestro da una vista por instante T de la rejilla del programa. El
// esclavo pinta su mitad con la vista de SU fotograma —la de su T o, si se perdió, una
// extrapolada de las dos últimas, marcada— y la parte viaja con la vista que usó de
// verdad. El maestro compone el instante T en el tic T + PART_MAX_WAIT_MS: con la parte
// a tiempo, pinta su mitad con la MISMA vista de la parte y su fotograma más cercano al
// de la parte, así que no hay desgarro por construcción; sin ella, ese fotograma sale de
// una lente y se cuenta.

import Foundation

/// El anillo de vistas del maestro, acotado por número. De él sale cada mensaje `view`.
public final class ViewHistory {
    private var ring: [ViewCommand] = []
    public let capacity: Int

    public init(capacity: Int = 64) {
        precondition(capacity >= LinkConstants.viewHistory, "el anillo tiene que caber un mensaje view")
        self.capacity = capacity
        ring.reserveCapacity(capacity)
    }

    public func append(_ command: ViewCommand) {
        if ring.count == capacity {
            ring.removeFirst()
        }
        ring.append(command)
    }

    /// Lo que lleva el próximo mensaje `view`: las VIEW_HISTORY últimas, de la más
    /// vieja a la más nueva.
    public func message() -> [ViewCommand] {
        Array(ring.suffix(LinkConstants.viewHistory))
    }

    /// La vista del instante `rigMs`, si está en el anillo.
    public func view(at rigMs: Int64) -> ViewCommand? {
        ring.last { $0.targetRigMs == rigMs }
    }
}

/// La vista con la que el esclavo pinta un fotograma, y si tuvo que inventarla.
public struct ResolvedView: Equatable, Sendable {
    public let command: ViewCommand
    public let extrapolated: Bool

    public init(command: ViewCommand, extrapolated: Bool) {
        self.command = command
        self.extrapolated = extrapolated
    }
}

/// El lado del esclavo: recibe mensajes `view` en cualquier orden, con pérdidas y
/// duplicados, y da la vista de cada fotograma suyo.
public final class SlaveViewResolver {
    private let halfFrameMs: Double
    private let capacity: Int
    /// Ordenadas por targetRigMs, sin duplicados.
    private var known: [ViewCommand] = []
    public private(set) var extrapolations = 0

    public init(frameDurationMs: Double, capacity: Int = 64) {
        halfFrameMs = frameDurationMs / 2
        self.capacity = capacity
        known.reserveCapacity(capacity)
    }

    public func receive(_ views: [ViewCommand]) {
        for v in views where !known.contains(where: { $0.targetRigMs == v.targetRigMs }) {
            let i = known.firstIndex { $0.targetRigMs > v.targetRigMs } ?? known.count
            known.insert(v, at: i)
        }
        if known.count > capacity {
            known.removeFirst(known.count - capacity)
        }
    }

    /// La vista para el fotograma de instante `frameRigMs`: la del instante a ≤½
    /// fotograma, o la extrapolación lineal de las dos últimas anteriores, marcada.
    /// `nil` si todavía no ha llegado ninguna.
    public func resolve(frameRigMs: Int64) -> ResolvedView? {
        if let exacta = known.last(where: { abs(Double($0.targetRigMs - frameRigMs)) <= halfFrameMs }) {
            return ResolvedView(command: exacta, extrapolated: false)
        }
        let previas = known.filter { $0.targetRigMs < frameRigMs }
        guard let ultima = previas.last ?? known.first else { return nil }
        extrapolations += 1
        guard previas.count >= 2 else {
            return ResolvedView(command: retarget(ultima, to: frameRigMs), extrapolated: true)
        }
        let penultima = previas[previas.count - 2]
        let dt = Double(ultima.targetRigMs - penultima.targetRigMs)
        let k = dt > 0 ? Double(frameRigMs - ultima.targetRigMs) / dt : 0
        func lerp(_ a: Double, _ b: Double) -> Double { b + (b - a) * k }
        return ResolvedView(
            command: ViewCommand(
                targetRigMs: frameRigMs,
                viewId: ultima.viewId,
                yawRad: lerp(penultima.yawRad, ultima.yawRad),
                pitchRad: lerp(penultima.pitchRad, ultima.pitchRad),
                hfovRad: lerp(penultima.hfovRad, ultima.hfovRad),
                sides: ultima.sides,
                seamYawRad: ultima.seamYawRad,
                featherRad: ultima.featherRad,
                gains: ultima.gains
            ),
            extrapolated: true
        )
    }

    private func retarget(_ v: ViewCommand, to rigMs: Int64) -> ViewCommand {
        ViewCommand(
            targetRigMs: rigMs, viewId: v.viewId, yawRad: v.yawRad, pitchRad: v.pitchRad,
            hfovRad: v.hfovRad, sides: v.sides, seamYawRad: v.seamYawRad,
            featherRad: v.featherRad, gains: v.gains
        )
    }
}

/// Lo que viaja con la parte del esclavo: de qué fotograma es y con qué vista se pintó.
public struct PartInfo: Equatable, Sendable {
    public let frameRigMs: Int64
    public let view: ResolvedView

    public init(frameRigMs: Int64, view: ResolvedView) {
        self.frameRigMs = frameRigMs
        self.view = view
    }
}

/// Cómo sale un instante del programa.
public enum ProgramFrame: Equatable, Sendable {
    /// Las dos mitades con la vista de la parte; el maestro usa su fotograma más
    /// cercano a `slaveFrameRigMs`.
    case twoLens(view: ViewCommand, slaveFrameRigMs: Int64)
    /// La parte no llegó a tiempo: una lente, con la vista del maestro.
    case oneLens(view: ViewCommand)
}

/// El lado del maestro: guarda las partes que llegan y compone cada instante en su
/// tic T + PART_MAX_WAIT_MS.
public final class ProgramSync {
    private let halfFrameMs: Double
    /// Lo que se espera la parte; 0 con el esclavo caído (IOS-81).
    public var maxWaitMs: Int64
    private let capacity: Int
    private var parts: [PartInfo] = []
    public private(set) var oneLensFrames = 0
    public private(set) var twoLensFrames = 0

    public init(
        frameDurationMs: Double, maxWaitMs: Int64 = LinkConstants.partMaxWaitMs, capacity: Int = 16
    ) {
        halfFrameMs = frameDurationMs / 2
        self.maxWaitMs = maxWaitMs
        self.capacity = capacity
        parts.reserveCapacity(capacity)
    }

    /// Una parte que llega. Acotado por número: la más vieja sale.
    public func receive(_ part: PartInfo) {
        parts.append(part)
        if parts.count > capacity {
            parts.removeFirst(parts.count - capacity)
        }
    }

    /// El instante T del programa, decidido en el tic `nowRigMs`. `nil` si todavía no es
    /// su hora: se compone siempre en T + maxWaitMs, para que el retardo sea fijo.
    public func compose(programRigMs t: Int64, nowRigMs: Int64, masterView: ViewCommand) -> ProgramFrame? {
        guard nowRigMs >= t + maxWaitMs else { return nil }
        // Lo que ya no puede servir a este instante ni a los siguientes, fuera.
        parts.removeAll { Double($0.frameRigMs) < Double(t) - halfFrameMs }
        if let i = parts.firstIndex(where: { abs(Double($0.frameRigMs - t)) <= halfFrameMs }) {
            let parte = parts.remove(at: i)
            twoLensFrames += 1
            return .twoLens(view: parte.view.command, slaveFrameRigMs: parte.frameRigMs)
        }
        oneLensFrames += 1
        return .oneLens(view: masterView)
    }
}
