// El director en vivo en el maestro (IOS-73).
//
// Las detecciones de las dos cámaras (las propias de IOS-25 y las del esclavo por el
// enlace) se emparejan por su instante de la rejilla (DetectionPairer, IOS-32): las dos
// usan los mismos t_k, así que su desfase es cero salvo pérdida. Cada pareja entra al
// DirectorLoop (IOS-37), que en cada tic del programa a 30 Hz da el ViewCommand que va a
// la sincronía de vistas (IOS-42) y al render. Las órdenes del operador (modo, IA,
// plano de situación) entran por aquí.

import Foundation
import RigCore

public final class DirectorService {
    private let loop: DirectorLoop
    private let pairer = DetectionPairer<[PlayerDetection]>()
    private let lock = NSLock()
    private let history = ViewHistory()
    public private(set) var cyclesIngested = 0

    public init(loop: DirectorLoop) {
        self.loop = loop
    }

    /// Las detecciones de una cámara en el instante `targetRigMs` (propias o del esclavo).
    public func receive(side: CameraSide, targetRigMs: Int64, detections: [PlayerDetection]) {
        lock.lock()
        defer { lock.unlock() }
        pairer.push(side, ptsNs: Int(targetRigMs) * 1_000_000, payload: detections)
        while let par = pairer.pop() {
            loop.ingest(left: par.left?.payload ?? [], right: par.right?.payload ?? [])
            cyclesIngested += 1
        }
    }

    /// El ViewCommand del instante `targetRigMs` del programa, y las últimas vistas para
    /// el mensaje `view`.
    public func tick(targetRigMs: Int64) throws -> (view: ViewCommand, history: [ViewCommand]) {
        lock.lock()
        defer { lock.unlock() }
        let v = try loop.tick(targetRigMs: targetRigMs)
        history.append(v)
        return (v, history.message())
    }

    public var pairing: PairingStats {
        lock.lock(); defer { lock.unlock() }
        return pairer.stats
    }

    // MARK: - Órdenes del operador

    public func setMode(_ mode: DirectorMode) {
        lock.lock(); loop.mode = mode; lock.unlock()
    }

    public func setAI(enabled: Bool) {
        lock.lock(); loop.aiEnabled = enabled; lock.unlock()
    }

    public func setGains(_ gains: ColorGains) {
        lock.lock(); loop.gains = gains; lock.unlock()
    }

    /// El otro móvil cayó (o volvió): a los límites de la lente que queda, o a las dos
    /// (IOS-81). No lanza: si la lente sola no da límites, se queda como estaba.
    public func setSingleLens(_ side: CameraSide?) {
        lock.lock(); defer { lock.unlock() }
        try? loop.setSingleLens(side)
    }

    public func markSituation() {
        lock.lock(); loop.markSituation(); lock.unlock()
    }
}
