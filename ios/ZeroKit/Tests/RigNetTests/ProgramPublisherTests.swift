import Foundation
import XCTest

import RigCore
@testable import RigNet

/// El publicador del programa (IOS-56) contra un socket falso: la cola, el IDR ante
/// congestión, el bitrate, la reconexión y que ningún secreto salga en estadísticas ni logs.
final class ProgramPublisherTests: XCTestCase {
    /// Un SrtSocket de mentira: decide si conecta, cuánto búfer tiene y cuánto traga.
    final class FakeSink: ProgramSrtSink {
        private let lock = NSLock()
        private var _connectErrors: [Error?]
        private var _connected = false
        private var _sent = Data()
        private var _bufferMs = 0
        private var _acceptBytes: Int?
        private var _sendRateMbps = 0.0
        private var _rttMs = 40.0
        private var _latencyMs: Int32?
        private(set) var connects = 0

        init(connectErrors: [Error?] = []) { _connectErrors = connectErrors }

        /// El RTT que da `stats()`: 40 ms, un 4G sano, si no se cambia.
        var rttMs: Double {
            get { locked { _rttMs } }
            set { locked { _rttMs = newValue } }
        }
        /// La latencia SRT con la que se le pidió conectar (SRTO_LATENCY); nil, aún no.
        var connectedLatencyMs: Int32? { locked { _latencyMs } }

        func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        var sent: Data { locked { _sent } }
        var bufferMs: Int {
            get { locked { _bufferMs } }
            set { locked { _bufferMs = newValue } }
        }
        var acceptBytes: Int? {
            get { locked { _acceptBytes } }
            set { locked { _acceptBytes = newValue } }
        }
        var sendRateMbps: Double {
            get { locked { _sendRateMbps } }
            set { locked { _sendRateMbps = newValue } }
        }
        func drop() { locked { _connected = false } }

        func connect(to target: ProgramSrtTarget, query: String?, latencyMs: Int32, timeoutMs: Int32) throws {
            // Como SrtSocket: el streamid y la passphrase, comprobados antes de salir.
            do {
                _ = try target.streamId(query: query)
                _ = try target.checkedPassphrase()
            } catch let e as ProgramSrtError {
                throw SrtError.invalid(e)
            }
            let error: Error? = locked {
                connects += 1
                _latencyMs = latencyMs
                return _connectErrors.isEmpty ? nil : _connectErrors.removeFirst()
            }
            if let error { throw error }
            locked { _connected = true }
        }

        var isConnected: Bool { locked { _connected } }

        func send(_ data: Data) throws -> Int {
            try locked {
                guard _connected else { throw SrtError.send(-1, "cortado") }
                let n = min(data.count, _acceptBytes ?? data.count)
                _sent += data.prefix(n)
                if let a = _acceptBytes { _acceptBytes = a - n }
                return n
            }
        }

        func stats(clear: Bool) throws -> SrtStats {
            locked {
                var s = SrtStats()
                s.sendBufferMs = Int32(_bufferMs)
                s.sendRateMbps = _sendRateMbps
                s.bytesSent = UInt64(_sent.count)
                s.rttMs = _rttMs
                return s
            }
        }

        func sendBufferMs() -> Int? { locked { _connected ? _bufferMs : nil } }
        func close() { locked { _connected = false } }
    }

    /// Un reloj que avanza a mano.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms = 0.0
        var now: Double { lock.lock(); defer { lock.unlock() }; return ms }
        func advance(_ d: Double) { lock.lock(); ms += d; lock.unlock() }
    }

    private let destino = ProgramSrtTarget(host: "vps.example", port: 8890, user: "maestro",
                                           pass: "clave-secreta-1", passphrase: "frase-secreta-del-srt")

    private func publisher(_ sinks: [FakeSink], clock: ManualClock? = nil, statsEveryS: Double = 0.05,
                           latencyMs: Int32 = ProgramSrt.latencyMs) -> (ProgramPublisher, Eventos) {
        var timing = ProgramPublisher.Timing()
        timing.statsEveryS = statsEveryS
        timing.reconnectScale = 0.01  // 3 s → 30 ms
        timing.latencyMs = latencyMs
        if let clock { timing.nowMs = { clock.now } }
        var restantes = sinks
        let p = ProgramPublisher(target: destino, audio: .init(sampleRate: 48_000, channels: 2),
                                 maximumBps: 6_000_000, timing: timing,
                                 makeSink: { restantes.count > 1 ? restantes.removeFirst() : restantes[0] })
        let e = Eventos()
        p.onIdrRequest = { e.add("idr") }
        p.onBitrate = { e.add("bitrate \($0)") }
        p.onState = { e.add("estado \($0)") }
        p.onLog = { e.add("log \($0)") }
        addTeardownBlock { p.stop() }
        return (p, e)
    }

    final class Eventos: @unchecked Sendable {
        private let lock = NSLock()
        private var lista: [String] = []
        func add(_ s: String) { lock.lock(); lista.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lista }
        func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
    }

    private func wait(_ what: String, timeout: Double = 3, _ cond: () -> Bool) {
        let fin = Date().addingTimeInterval(timeout)
        while !cond() && Date() < fin { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(cond(), what)
    }

    /// Una muestra AVCC de un solo NAL: IDR (5) o P (1).
    private func au(_ key: Bool, _ n: Int = 1000) -> Data {
        var nal = Data([key ? 0x65 : 0x41])
        nal += Data(repeating: 0xAB, count: n)
        return withUnsafeBytes(of: UInt32(nal.count).bigEndian) { Data($0) } + nal
    }

    private func pids(_ ts: Data) -> [UInt16] {
        stride(from: 0, to: ts.count, by: TsFormat.packetSize).map {
            UInt16(ts[$0 + 1] & 0x1F) << 8 | UInt16(ts[$0 + 2])
        }
    }

    func testPublishesFromTheFirstIdrAfterConnecting() {
        let sink = FakeSink()
        let (p, e) = publisher([sink])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        XCTAssertEqual(e.count("idr"), 1, "al conectar se pide un IDR")
        p.audio(aacRaw: Data(repeating: 1, count: 300), rigMs: 990)  // antes del IDR: fuera
        p.video(avcc: au(false), isKeyframe: false, rigMs: 1000)    // P antes del IDR: fuera
        p.video(avcc: au(true), isKeyframe: true, rigMs: 1033)
        p.audio(aacRaw: Data(repeating: 1, count: 300), rigMs: 1040)
        p.video(avcc: au(false), isKeyframe: false, rigMs: 1066)
        wait("envía") { p.snapshot.videoFramesSent == 2 }
        let s = p.snapshot
        XCTAssertEqual(s.audioFramesSent, 1)
        XCTAssertEqual(s.videoDropped, 1)
        XCTAssertEqual(s.audioDropped, 1)
        XCTAssertEqual(s.lastSentRigMs, 1066)
        let ts = sink.sent
        XCTAssertEqual(ts.count % TsFormat.packetSize, 0)
        // PAT, PMT y el IDR; luego el audio y el P.
        XCTAssertEqual(Array(pids(ts).prefix(3)), [0, TsFormat.pmtPid, TsFormat.videoPid])
        XCTAssertTrue(pids(ts).contains(TsFormat.audioPid))
    }

    func testACongestedSrtHoldsThenDropsUntilAnIdrAndBacksOff() {
        let sink = FakeSink()
        let reloj = ManualClock()
        let (p, e) = publisher([sink], clock: reloj, statsEveryS: 3600)  // la muestra, a mano
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        // SRT con 900 ms sin confirmar: no se le da más y la cola crece.
        sink.bufferMs = 900
        for i in 1...32 {
            reloj.advance(1000.0 / 30)
            p.video(avcc: au(false), isKeyframe: false, rigMs: Double(i) * 33)
        }
        wait("a 1 s de espera, se tira") { p.snapshot.congestions == 1 }
        var s = p.snapshot
        XCTAssertEqual(s.videoFramesSent, 1)
        XCTAssertEqual(s.videoDropped, 32)  // el primero esperaba 1033 ms al llegar el 32.º
        XCTAssertGreaterThan(s.sendHolds, 0)
        // Con SRT retenido el IDR no se pide (llegaría retenido y se tiraría al segundo):
        // queda pendiente hasta que el búfer baje.
        XCTAssertEqual(e.count("idr"), 1, "el de conectar; el de la congestión, pendiente")
        sink.bufferMs = 10
        p.video(avcc: au(false), isKeyframe: false, rigMs: 1100)
        wait("baja el búfer: ahora sí se pide el IDR") { e.count("idr") == 2 }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 1133)
        wait("vuelve con el IDR") { p.snapshot.videoFramesSent == 2 }
        s = p.snapshot
        XCTAssertEqual(s.videoDropped, 33)
        XCTAssertEqual(s.idrRequests, 2)
        XCTAssertEqual(s.stallReconnects, 0)
        XCTAssertEqual(e.count("idr"), 2, "no se pide otro mientras se espera")
    }

    /// El atasco del 2026-10-15: la conexión sigue viva pero el búfer de envío de SRT no
    /// baja nunca (el otro lado dejó de confirmar), así que se retiene para siempre. A los
    /// 5 s sin sacar vídeo, el vigía cierra y reconecta; el informe dice desde cuándo.
    func testAStalledConnectionIsReconnectedAfterFiveSecondsWithoutVideoOut() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, e) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        primero.bufferMs = 900  // y ahí se queda: ninguna confirmación lo baja
        var rig = 0.0
        for _ in 1...90 {  // 3 s de fotogramas
            reloj.advance(1000.0 / 30)
            rig += 1000.0 / 30
            p.video(avcc: au(false), isKeyframe: false, rigMs: rig)
        }
        p.sampleNow()
        var s = p.snapshot
        XCTAssertEqual(s.stallReconnects, 0, "a los 3 s aún no es un atasco")
        XCTAssertEqual(s.state, "publishing")
        XCTAssertEqual(s.videoFramesSent, 1)
        XCTAssertEqual(s.lastSentAgeS ?? 0, 3.0, accuracy: 0.05)
        for _ in 1...62 {  // pasa de 5 s desde el primer P que no salió (2,07 s más)
            reloj.advance(1000.0 / 30)
            rig += 1000.0 / 30
            p.video(avcc: au(false), isKeyframe: false, rigMs: rig)
        }
        p.sampleNow()
        s = p.snapshot
        XCTAssertEqual(s.stallReconnects, 1)
        XCTAssertEqual(s.lastError, "SRT vivo pero 5 s sin sacar vídeo (búfer de envío 900 ms)")
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log atasco: SRT vivo pero 5 s sin sacar vídeo") }, "\(e.all)")
        XCTAssertFalse(primero.isConnected, "se cerró la conexión atascada")
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connects, 1)
        XCTAssertEqual(e.count("idr"), 2, "un IDR al reconectar")
        p.video(avcc: au(true), isKeyframe: true, rigMs: rig + 33)
        wait("vuelve a salir vídeo") { p.snapshot.videoFramesSent == 2 }
        XCTAssertEqual(p.snapshot.lastSentAgeS ?? 1, 0, accuracy: 0.05)
    }

    func testNoVideoArrivingIsNotAStall() {
        let sink = FakeSink()
        let reloj = ManualClock()
        let (p, _) = publisher([sink], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        // El codificador se calla (segundo plano): nada que sacar, nada que reconectar.
        sink.bufferMs = 900
        reloj.advance(20_000)
        p.sampleNow()
        XCTAssertEqual(p.snapshot.stallReconnects, 0)
        XCTAssertEqual(p.snapshot.state, "publishing")
        XCTAssertNil(p.snapshot.lastError)
    }

    /// El búfer de envío por encima de la latencia SRT (libsrt ya tira paquetes sueltos):
    /// dos GOP así y se reconecta, aunque algún fotograma siga saliendo.
    func testASendBufferAboveTheLatencyForTwoGopsReconnects() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, _) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        primero.bufferMs = 1520  // la latencia (1500) más los 20 ms de libsrt
        for i in 0..<4 {
            p.sampleNow()
            XCTAssertEqual(p.snapshot.stallReconnects, 0, "a los \(i) s todavía no")
            reloj.advance(1000)
            // El búfer baja un instante por debajo del tope entre muestras: sale algo.
            primero.bufferMs = 700
            p.video(avcc: au(false), isKeyframe: false, rigMs: Double(i + 1) * 1000)
            wait("sale") { p.snapshot.videoFramesSent == i + 2 }
            primero.bufferMs = 1520
        }
        p.sampleNow()
        let s = p.snapshot
        XCTAssertEqual(s.stallReconnects, 1)
        XCTAssertEqual(s.lastError, "SRT con el búfer de envío (1520 ms) por encima de la latencia (1500 ms) durante 4 s")
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connects, 1)
    }

    func testTheBufferDroppingBelowTheLatencyResetsTheCount() {
        let sink = FakeSink()
        let reloj = ManualClock()
        let (p, _) = publisher([sink], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        for _ in 0..<3 {
            sink.bufferMs = 1600
            p.sampleNow()
            reloj.advance(3000)
            sink.bufferMs = 1400
            p.sampleNow()
        }
        XCTAssertEqual(p.snapshot.stallReconnects, 0)
        XCTAssertEqual(p.snapshot.state, "publishing")
    }

    // MARK: - La latencia SRT que sube cuando la red lo pide (2026-10-15)

    /// Avanza `s` segundos de fotogramas P a 30 fps que no salen (SRT retenido).
    private func feedUnsent(_ p: ProgramPublisher, _ reloj: ManualClock, seconds s: Double, from rig: inout Double) {
        for _ in 1...Int(s * 30) {
            reloj.advance(1000.0 / 30)
            rig += 1000.0 / 30
            p.video(avcc: au(false), isKeyframe: false, rigMs: rig)
        }
    }

    /// La pasada empieza en 1500 ms; el atasco del vigía reconecta al segundo (no a los 3 s)
    /// y con el escalón siguiente, 2500 ms; el umbral de retención pasa a ser su mitad: un
    /// búfer de 900 ms, que antes retenía, ya deja pasar vídeo.
    func testAStallReconnectsInOneSecondWithTheNextLatencyStepAndItsThreshold() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, e) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        XCTAssertEqual(primero.connectedLatencyMs, 1500, "una pasada nueva empieza en el primer escalón")
        XCTAssertEqual(p.snapshot.latencyMs, 1500)
        XCTAssertEqual(p.snapshot.latencyRaises, 0)
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        primero.bufferMs = 900  // > 750, la mitad de 1500: retenido
        var rig = 0.0
        feedUnsent(p, reloj, seconds: 5.1, from: &rig)
        p.sampleNow()
        XCTAssertEqual(p.snapshot.stallReconnects, 1)
        XCTAssertEqual(p.snapshot.latencyMs, 2500)
        XCTAssertEqual(p.snapshot.latencyRaises, 1)
        XCTAssertTrue(e.all.contains("log latencia SRT 1,5 s → 2,5 s: atasco (rtt máx 40 ms, búfer máx 900 ms)"), "\(e.all)")
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log SRT vivo pero 5 s sin sacar vídeo") && $0.hasSuffix("otra vez en 1 s") }, "\(e.all)")
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connectedLatencyMs, 2500)
        XCTAssertTrue(e.all.contains("log conectado a vps.example:8890 · latencia SRT 2,5 s"), "\(e.all)")
        let retencionesAntes = p.snapshot.sendHolds  // las de la conexión atascada
        segundo.bufferMs = 900  // < 1250, la mitad de 2500: ya no retiene
        p.video(avcc: au(true), isKeyframe: true, rigMs: rig + 33)
        wait("sale con el umbral nuevo") { p.snapshot.videoFramesSent == 2 }
        XCTAssertEqual(p.snapshot.sendHolds, retencionesAntes, "con 2500 ms de latencia, 900 ms de búfer no es retención")
    }

    /// Un corte normal (la conexión se cayó) también sube la latencia si en esa conexión el
    /// RTT pasó de la mitad de la latencia: el ARQ no llegaba a tiempo.
    func testALostConnectionWithRttOverHalfTheLatencyReconnectsWithMoreLatency() {
        let primero = FakeSink(), segundo = FakeSink()
        let (p, e) = publisher([primero, segundo])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        primero.rttMs = 1200  // > 750
        p.sampleNow()
        XCTAssertEqual(p.snapshot.latencyMs, 1500, "con la conexión viva no se puede cambiar: solo al reconectar")
        primero.drop()
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connectedLatencyMs, 2500)
        XCTAssertEqual(p.snapshot.latencyRaises, 1)
        XCTAssertTrue(e.all.contains("log latencia SRT 1,5 s → 2,5 s: rtt máx 1200 ms, búfer máx 0 ms"), "\(e.all)")
        XCTAssertTrue(e.all.contains("log SRT sin conectar; otra vez en 3 s"), "un corte de verdad sigue esperando 3 s")
    }

    func testALostConnectionWithAHealthyNetworkKeepsTheLatency() {
        let primero = FakeSink(), segundo = FakeSink()
        let (p, e) = publisher([primero, segundo])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.sampleNow()  // rtt 40, búfer 0
        primero.drop()
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connectedLatencyMs, 1500)
        XCTAssertEqual(p.snapshot.latencyRaises, 0)
        XCTAssertFalse(e.all.contains { $0.hasPrefix("log latencia SRT") }, "\(e.all)")
    }

    /// La escalera tiene tope (4000 ms) y no baja: tres atascos seguidos, dos subidas.
    func testTheLatencyStopsAtTheTopAndNeverComesDown() {
        let sinks = [FakeSink(), FakeSink(), FakeSink(), FakeSink()]
        let reloj = ManualClock()
        let (p, e) = publisher(sinks, clock: reloj, statsEveryS: 3600)
        p.start()
        var rig = 0.0
        for (i, esperado) in [2500, 4000, 4000].enumerated() {
            wait("conecta \(i)") { p.snapshot.state == "publishing" && p.snapshot.connects == i + 1 }
            p.video(avcc: au(true), isKeyframe: true, rigMs: rig)
            wait("sale el IDR \(i)") { p.snapshot.videoFramesSent == i + 1 }
            sinks[i].bufferMs = 3000  // por encima de la mitad de cualquier escalón
            feedUnsent(p, reloj, seconds: 5.1, from: &rig)
            p.sampleNow()
            XCTAssertEqual(p.snapshot.stallReconnects, i + 1)
            XCTAssertEqual(p.snapshot.latencyMs, esperado, "tras el atasco \(i + 1)")
            rig += 1000
        }
        wait("conecta la cuarta") { p.snapshot.state == "publishing" && p.snapshot.connects == 4 }
        XCTAssertEqual(sinks.map(\.connectedLatencyMs), [1500, 2500, 4000, 4000])
        XCTAssertEqual(p.snapshot.latencyRaises, 2)
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log latencia SRT en el tope (4 s); atasco") }, "\(e.all)")
        // Y otra pasada (otro publicador) vuelve a empezar en 1500.
        let (otra, _) = publisher([FakeSink()])
        XCTAssertEqual(otra.snapshot.latencyMs, 1500)
    }

    /// Congestión sostenida sin atasco: el búfer pasa de la mitad de la latencia en cada
    /// muestra durante 10 s aunque entre muestras baje y salga vídeo. Se reconecta con el
    /// escalón siguiente; en el tope, no (no ganaría nada).
    func testTenSecondsOfCongestionReconnectWithMoreLatencyUnlessAtTheTop() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, _) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        for i in 0..<10 {
            primero.bufferMs = 800  // > 750 en la muestra
            p.sampleNow()
            XCTAssertEqual(p.snapshot.stallReconnects, 0, "a los \(i) s todavía no")
            reloj.advance(1000)
            primero.bufferMs = 700  // entre muestras baja: sale vídeo, no es un atasco
            p.video(avcc: au(false), isKeyframe: false, rigMs: Double(i + 1) * 1000)
            wait("sale") { p.snapshot.videoFramesSent == i + 2 }
        }
        primero.bufferMs = 800
        p.sampleNow()
        let s = p.snapshot
        XCTAssertEqual(s.stallReconnects, 1)
        XCTAssertEqual(s.lastError, "SRT congestionado 10 s seguidos (búfer de envío 800 ms, latencia 1500 ms): más latencia")
        XCTAssertEqual(s.latencyMs, 2500)
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connectedLatencyMs, 2500)

        // En el tope: la misma congestión no reconecta.
        let tope = FakeSink()
        let reloj2 = ManualClock()
        let (q, _) = publisher([tope], clock: reloj2, statsEveryS: 3600, latencyMs: 4000)
        q.start()
        wait("conecta en el tope") { q.snapshot.state == "publishing" }
        for _ in 0..<12 {
            tope.bufferMs = 2100  // > 2000, la mitad de 4000
            q.sampleNow()
            reloj2.advance(1000)
        }
        XCTAssertEqual(q.snapshot.stallReconnects, 0)
        XCTAssertEqual(q.snapshot.state, "publishing")
        XCTAssertEqual(q.snapshot.latencyMs, 4000)
    }

    /// Un IDR pedido que el codificador nunca entrega deja la cola tirando todo: a los 5 s es
    /// un atasco y se reconecta (el programa no se queda esperando un IDR para siempre).
    func testAnIdrThatNeverArrivesIsAStallAndReconnects() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, e) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        // SRT corta un fotograma a medias: la cola tira hasta el IDR y lo pide.
        primero.acceptBytes = 188
        p.video(avcc: au(false), isKeyframe: false, rigMs: 33)
        wait("pide el IDR") { e.count("idr") == 2 }
        primero.acceptBytes = nil
        // El codificador solo trae P: nada sale.
        var rig = 33.0
        feedUnsent(p, reloj, seconds: 5.1, from: &rig)
        p.sampleNow()
        XCTAssertEqual(p.snapshot.stallReconnects, 1)
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log atasco: SRT vivo pero 5 s sin sacar vídeo") && $0.hasSuffix("cola esperando IDR") }, "\(e.all)")
        wait("reconecta") { p.snapshot.reconnects == 1 && p.snapshot.state == "publishing" }
        XCTAssertEqual(segundo.connects, 1)
        XCTAssertEqual(e.count("idr"), 3, "otro IDR al reconectar")
    }

    func testTheSecondSampleBacksOffTheBitrateWhenSrtIsCongested() {
        let sink = FakeSink()
        let (p, e) = publisher([sink], statsEveryS: 0.05)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        sink.sendRateMbps = 3
        sink.bufferMs = 900
        wait("baja a 0,8 × lo que salió") { e.all.contains("bitrate 2400000") }
        XCTAssertEqual(p.bitrateBps, 2_400_000)
        XCTAssertEqual(p.snapshot.bitrateMinBps, 2_400_000)
        // Con la escalera en L3 el techo baja de inmediato, aunque no haya congestión.
        sink.bufferMs = 20
        p.setCeiling(bps: 2_000_000)
        wait("techo de la escalera") { p.bitrateBps == 2_000_000 }
    }

    func testAFrameCutInHalfBySrtDropsUntilTheNextIdr() {
        let sink = FakeSink()
        let (p, e) = publisher([sink], statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        sink.acceptBytes = 3 * TsFormat.packetSize
        p.video(avcc: au(true, 5000), isKeyframe: true, rigMs: 0)
        p.video(avcc: au(false), isKeyframe: false, rigMs: 33)
        wait("pide IDR") { e.count("idr") == 2 }
        sink.acceptBytes = nil
        p.video(avcc: au(false), isKeyframe: false, rigMs: 66)
        p.video(avcc: au(true), isKeyframe: true, rigMs: 100)
        wait("vuelve con el IDR") { p.snapshot.videoFramesSent == 1 }
        let s = p.snapshot
        XCTAssertEqual(s.partialSends, 1)
        XCTAssertEqual(s.videoDropped, 2)
    }

    func testReconnectsAfterALostConnectionAndStartsAgainAtAnIdr() {
        let primero = FakeSink(), segundo = FakeSink()
        let (p, e) = publisher([primero, segundo])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("envía") { p.snapshot.videoFramesSent == 1 }
        primero.drop()
        wait("se da cuenta en la muestra y reconecta") { p.snapshot.reconnects == 1 }
        XCTAssertEqual(segundo.connects, 1)
        XCTAssertEqual(e.count("idr"), 2, "un IDR por conexión")
        XCTAssertTrue(e.all.contains("log SRT sin conectar; otra vez en 3 s"))
        p.video(avcc: au(false), isKeyframe: false, rigMs: 33)
        p.video(avcc: au(true), isKeyframe: true, rigMs: 66)
        wait("el TS nuevo empieza por la PAT") { p.snapshot.videoFramesSent == 2 }
        XCTAssertEqual(pids(segundo.sent).first, 0)
        XCTAssertEqual(p.snapshot.connects, 2)
    }

    func testWhatWasDroppedDuringTheCutDoesNotLowerTheBitrateAfterReconnecting() {
        let primero = FakeSink(), segundo = FakeSink()
        let reloj = ManualClock()
        let (p, e) = publisher([primero, segundo], clock: reloj, statsEveryS: 3600)
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        wait("sale el IDR") { p.snapshot.videoFramesSent == 1 }
        // El servidor deja de confirmar: la cola se congestiona y luego se ve el corte.
        primero.bufferMs = 900
        for i in 1...32 {
            reloj.advance(1000.0 / 30)
            p.video(avcc: au(i == 32), isKeyframe: i == 32, rigMs: Double(i) * 33)
        }
        wait("congestión") { p.snapshot.congestions == 1 }
        primero.drop()
        p.video(avcc: au(true), isKeyframe: true, rigMs: 1100)
        wait("reconecta") { p.snapshot.reconnects == 1 }
        segundo.sendRateMbps = 6
        p.sampleNow()
        XCTAssertEqual(p.bitrateBps, 6_000_000)
        XCTAssertEqual(e.count("bitrate"), 0)
    }

    func testWhileDownEverythingIsDroppedAndCounted() {
        let sink = FakeSink(connectErrors: [SrtError.timeout, SrtError.timeout, SrtError.timeout])
        let (p, _) = publisher([sink])
        p.start()
        wait("primer fallo") { p.snapshot.connectFailures >= 1 }
        for i in 0..<10 { p.video(avcc: au(i == 0), isKeyframe: i == 0, rigMs: Double(i)) }
        wait("conecta al cuarto intento") { p.snapshot.state == "publishing" }
        let s = p.snapshot
        XCTAssertEqual(s.connectFailures, 3)
        XCTAssertEqual(s.reconnects, 0, "nunca había conectado")
        XCTAssertGreaterThan(s.videoDroppedWhileDown, 0)
        XCTAssertEqual(s.lastError, "SRT: sin respuesta del servidor")
    }

    func testRejectionsBackOffAndABadTargetFailsForGood() {
        let rechazos: [Error?] = [SrtError.rejected(SrtError.rejectPeer), SrtError.rejected(SrtError.rejectPeer)]
        let (p, e) = publisher([FakeSink(connectErrors: rechazos)])
        p.start()
        wait("conecta tras dos rechazos") { p.snapshot.state == "publishing" }
        XCTAssertEqual(p.snapshot.rejections, 2)
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log SRT rechazado") && $0.hasSuffix("otra vez en 3 s") })
        XCTAssertTrue(e.all.contains { $0.hasPrefix("log SRT rechazado") && $0.hasSuffix("otra vez en 6 s") })

        // Un «:» en la clave no se arregla reintentando.
        let malo = ProgramPublisher(target: ProgramSrtTarget(host: "vps.example", port: 8890, user: "maestro",
                                                             pass: "cla:ve", passphrase: "frase-secreta-del-srt"),
                                    audio: nil, maximumBps: 6_000_000, makeSink: { FakeSink() })
        malo.start()
        wait("falla") { malo.snapshot.state == "failed" }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(malo.snapshot.connectFailures, 1)
        malo.stop()
    }

    func testStopIsFinal() {
        let sink = FakeSink()
        let (p, _) = publisher([sink])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        p.stop()
        XCTAssertFalse(sink.isConnected)
        p.video(avcc: au(true), isKeyframe: true, rigMs: 0)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(p.snapshot.state, "stopped")
        XCTAssertEqual(p.snapshot.videoFramesSent, 0)
        XCTAssertEqual(sink.connects, 1)
    }

    func testNoSecretInStatsOrLogs() throws {
        let rechazos: [Error?] = [SrtError.rejected(SrtError.rejectPeer)]
        let (p, e) = publisher([FakeSink(connectErrors: rechazos)])
        p.start()
        wait("conecta") { p.snapshot.state == "publishing" }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try enc.encode(p.snapshot), as: UTF8.self)
        XCTAssertTrue(json.contains("\"video_frames_sent\""))
        for texto in e.all + [json] {
            for secreto in [destino.user, destino.pass, destino.passphrase] {
                XCTAssertFalse(texto.contains(secreto), "«\(texto)» lleva un secreto")
            }
        }
        XCTAssertTrue(e.all.contains("log publicando en vps.example:8890"))
    }
}
