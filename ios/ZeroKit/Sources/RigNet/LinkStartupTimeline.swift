// Cuándo sube cada pieza del enlace en un banco (2026-10-11).
//
// En `bench/dos-moviles-20261010-1106` el maestro no vio al esclavo hasta los 102 s y
// los informes no decían si tardó el control, el canal de medios o el propio esclavo en
// abrir su enlace. Aquí se guarda la primera vez de cada hito, en ms desde que arrancó
// el banco, y la línea de tiempo del transporte con su arranque aunque la pasada dure
// un partido entero.

import Foundation

/// Los sucesos del transporte para el informe: los primeros `headCount` (el arranque,
/// lo que más se pregunta) y los últimos `tailCount`, con una marca de cuántos faltan
/// en medio. Antes solo se guardaban los últimos 80 y en una pasada larga el arranque
/// se perdía.
public struct LinkEventLog: Equatable, Sendable {
    public let headCount: Int
    public let tailCount: Int
    private var head: [String] = []
    private var tail: [String] = []
    /// Los que salieron de la cola del final sin guardarse.
    public private(set) var skipped = 0

    public init(headCount: Int, tailCount: Int) {
        self.headCount = max(0, headCount)
        self.tailCount = max(1, tailCount)
    }

    public mutating func append(_ suceso: String) {
        if head.count < headCount {
            head.append(suceso)
            return
        }
        tail.append(suceso)
        if tail.count > tailCount {
            tail.removeFirst(tail.count - tailCount)
            skipped += 1
        }
    }

    /// En orden: el arranque, la marca de lo que falta (si falta algo) y lo último.
    public var lines: [String] {
        head + (skipped > 0 ? ["… \(skipped) sucesos sin guardar …"] : []) + tail
    }
}

/// La primera vez de cada hito del enlace en un banco, en ms desde que arrancó. Se
/// apunta desde cualquier hilo; solo cuenta la primera.
public final class LinkStartupTimeline: @unchecked Sendable {
    public enum Milestone: String, CaseIterable, Sendable {
        /// El TCP de control, listo (del transporte).
        case controlUp = "control_up"
        /// La primera trama de medios del otro: el canal de medios, arriba (del transporte).
        case peerMedia = "media_rx"
        /// El apretón de manos hecho: la sesión, conectada.
        case sessionUp = "session_up"
        /// El maestro ve los latidos del esclavo (PeerHealth arriba).
        case peerUp = "peer_up"
        /// El esclavo recibe la primera vista del maestro.
        case firstView = "first_view"
        /// El esclavo manda su primera parte.
        case firstPartSent = "first_part_sent"
        /// Al maestro le llega la primera parte.
        case firstPart = "first_part"
    }

    /// El arranque del banco, en ns de uptime (`DispatchTime`).
    public let startNs: UInt64
    private let lock = NSLock()
    private var marks: [Milestone: UInt64] = [:]

    public init(startNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startNs = startNs
    }

    /// Apunta el hito si es la primera vez.
    public func mark(_ hito: Milestone, atNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        if marks[hito] == nil { marks[hito] = atNs }
    }

    /// Todos los hitos en ms desde el arranque, −1 los que no llegaron. Los del control y
    /// los medios salen de los contadores del transporte si se le pasan.
    public func report(transport: LinkTransportStats? = nil) -> [String: Int] {
        if let transport {
            if let ns = transport.firstControlUpNs { mark(.controlUp, atNs: ns) }
            if let ns = transport.firstPeerMediaNs { mark(.peerMedia, atNs: ns) }
        }
        lock.lock(); defer { lock.unlock() }
        var salida: [String: Int] = [:]
        for hito in Milestone.allCases {
            salida[hito.rawValue] = marks[hito].map { msSinceStart($0) } ?? -1
        }
        return salida
    }

    /// ms desde el arranque del banco (negativo si fue antes).
    public func msSinceStart(_ ns: UInt64) -> Int {
        Int((Double(Int64(bitPattern: ns &- startNs)) / 1e6).rounded())
    }

    /// Cuándo arrancó este proceso, en ms Unix, o nil si el sistema no lo dice. Con la
    /// hora del arranque del banco dice cuánto tardó la app en abrir el enlace desde que
    /// la lanzaron (`devicectl … process launch`).
    public static func processStartUnixMs() -> Int64? {
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &tamano, nil, 0) == 0, tamano > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        guard t.tv_sec > 0 else { return nil }
        return Int64(t.tv_sec) * 1000 + Int64(t.tv_usec) / 1000
    }
}
