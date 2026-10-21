// El diagnóstico del enlace desde que se abre hasta que enlaza, en un fichero (2026-10-15).
//
// En el EMITIR automático de las 11:36 los dos iPhone pasaron 5 min «buscando» y no quedó
// nada que dijera por qué: el diagnóstico de f0df022 va en el latido y el informe de una
// pasada del programa, y EMITIR no llegó a arrancar. Esto lo escribe el propio enlace, sea
// cual sea la pantalla: cada `periodS` mientras no hay sesión, una vez al enlazar y otra vez
// cada periodo si se cae. Y da la frase para la fila Enlace de la pantalla mientras busca.

import Foundation

public final class LinkDiagnosisRecorder {
    /// Lo que se lee del enlace en cada vuelta.
    public struct Sample {
        public var diagnosis: LinkDiagnosis
        public var session: RigLinkSession.State
        public var events: [String]
        public var stats: LinkTransportStats

        public init(diagnosis: LinkDiagnosis, session: RigLinkSession.State, events: [String],
                    stats: LinkTransportStats) {
            self.diagnosis = diagnosis
            self.session = session
            self.events = events
            self.stats = stats
        }
    }

    /// Segundos entre dos escrituras sin enlace: el diagnóstico cambia por citas de 20-30 s
    /// (los vigías de la suscripción y la publicación), y la pantalla cuenta los segundos.
    public static let periodS: Double = 10

    /// El nombre del fichero en `Documents/bench`, con el lado y la hora de arranque, como
    /// los demás de la cancha (`tools/cancha.py` lo recoge por ese nombre).
    public static func fileName(side: String, startUnixS: Int) -> String {
        "link-diag-\(side)-\(startUnixS).json"
    }

    /// Si se escribe en esta vuelta: sin enlace, siempre; con él, solo la primera vez.
    public static func shouldWrite(linked: Bool, lastWrittenLinked: Bool?) -> Bool {
        !linked || lastWrittenLinked != true
    }

    public var onSummary: ((String) -> Void)?

    private let side: String
    private let sample: () -> Sample
    private let write: (Data) -> Void
    private let nowNs: () -> UInt64
    private let startNs: UInt64
    private let startUnixMs: Int64
    private let queue = DispatchQueue(label: "io.footballai.zero.link.diag")
    private var timer: DispatchSourceTimer?
    private var lastWrittenLinked: Bool?
    private var linkedAfterS: Double?
    private var drops = 0
    public private(set) var writes = 0

    /// `sample` no puede leer en la cola del transporte (lo hace con `queue.sync`); aquí se
    /// llama desde una cola propia.
    public init(side: String, startUnixMs: Int64, sample: @escaping () -> Sample, write: @escaping (Data) -> Void,
                nowNs: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.side = side
        self.startUnixMs = startUnixMs
        self.sample = sample
        self.write = write
        self.nowNs = nowNs
        startNs = nowNs()
    }

    /// Escribe ya (el enlace se abre) y luego cada `periodS`.
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            tick()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.periodS, repeating: Self.periodS)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    /// Escribe una última vez (el enlace se cierra) y para.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            tick(force: true)
        }
    }

    /// Una vuelta: lee el enlace, da la frase si no hay sesión y escribe si toca. Devuelve si
    /// escribió. Pública para los tests.
    @discardableResult
    public func tick(force: Bool = false) -> Bool {
        let m = sample()
        let enlazado: Bool = if case .connected = m.session { true } else { false }
        let s = Double(nowNs() &- startNs) / 1e9
        if enlazado, linkedAfterS == nil { linkedAfterS = s }
        if !enlazado, lastWrittenLinked == true { drops += 1 }
        let frase = m.diagnosis.summary(session: m.session)
        if !enlazado { onSummary?(frase) }
        guard force || Self.shouldWrite(linked: enlazado, lastWrittenLinked: lastWrittenLinked) else { return false }
        lastWrittenLinked = enlazado
        writes += 1
        var informe: [String: Any] = [
            "side": side,
            "link_start_unix_ms": startUnixMs,
            "elapsed_s": (s * 10).rounded() / 10,
            "linked": enlazado,
            "drops_seen": drops,
            "writes": writes,
            "summary": frase,
            "link": m.diagnosis.report(session: m.session),
            "transport_events": m.events,
            "stats": [
                "reconnects": m.stats.reconnects, "silence_drops": m.stats.silenceDrops,
                "rendezvous_ends": m.stats.rendezvousEnds, "resubscribes": m.stats.resubscribes,
                "republishes": m.stats.republishes, "search_resets": m.stats.searchResets,
            ],
        ]
        if let linkedAfterS { informe["linked_after_s"] = (linkedAfterS * 10).rounded() / 10 }
        if let datos = try? JSONSerialization.data(withJSONObject: informe, options: [.prettyPrinted, .sortedKeys]) {
            write(datos)
        }
        return true
    }
}
