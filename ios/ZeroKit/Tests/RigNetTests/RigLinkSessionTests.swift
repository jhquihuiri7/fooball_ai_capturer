import Foundation
import XCTest

import RigCore
@testable import RigNet

/// La sesión del enlace con un transporte falso (IOS-12): apretón, reloj, PTS,
/// órdenes y la ventana contra repeticiones, sin abrir un solo socket.
final class RigLinkSessionTests: XCTestCase {
    private let secreto = Data(repeating: 0x33, count: 32)

    // MARK: - El transporte falso

    final class FakeLinkTransport: LinkTransport {
        var onFrame: ((LinkFrame, LinkChannel) -> Void)?
        var onState: ((LinkTransportState) -> Void)?
        var onPath: ((String) -> Void)?
        private(set) var state: LinkTransportState = .idle
        private(set) var stats = LinkTransportStats()

        /// A quién entrega lo que se manda. `nil` = el cable cortado.
        weak var peer: FakeLinkTransport?
        private(set) var sent: [(frame: LinkFrame, channel: LinkChannel)] = []
        /// Lo llegado antes de `start()`: un socket cerrado no entrega nada.
        private var inbox: [(LinkFrame, LinkChannel)] = []
        private let lock = NSLock()

        func start() {
            state = .connected
            onState?(.connected)
            lock.lock()
            let pendientes = inbox
            inbox.removeAll()
            lock.unlock()
            pendientes.forEach { onFrame?($0.0, $0.1) }
        }

        func stop() {
            state = .idle
        }

        func send(_ frame: LinkFrame, on channel: LinkChannel) {
            lock.lock()
            sent.append((frame, channel))
            lock.unlock()
            peer?.receive(frame, on: channel)
        }

        private func receive(_ frame: LinkFrame, on channel: LinkChannel) {
            lock.lock()
            let abierto = state == .connected
            if !abierto { inbox.append((frame, channel)) }
            lock.unlock()
            if abierto { onFrame?(frame, channel) }
        }

        func sentFrames(of type: LinkFrameType) -> [LinkFrame] {
            lock.lock()
            defer { lock.unlock() }
            return sent.filter { $0.frame.type == type }.map(\.frame)
        }
    }

    private func makePair(
        rightSecret: Data? = nil,
        rightSide: RigLinkSession.Side = .right
    ) -> (left: RigLinkSession, right: RigLinkSession, cableLeft: FakeLinkTransport, cableRight: FakeLinkTransport) {
        let cableLeft = FakeLinkTransport()
        let cableRight = FakeLinkTransport()
        cableLeft.peer = cableRight
        cableRight.peer = cableLeft
        let left = RigLinkSession(
            transport: cableLeft, secret: secreto, side: .left,
            deviceId: "iphone-izq", appVersion: "1.0"
        )
        let right = RigLinkSession(
            transport: cableRight, secret: rightSecret ?? secreto, side: rightSide,
            deviceId: "iphone-der", appVersion: "1.0"
        )
        let lock = NSLock()
        nonisolated(unsafe) var t = Int64(1_000)
        let reloj: () -> Int64 = {
            lock.lock()
            defer { lock.unlock() }
            t += 10
            return t
        }
        left.hostNowNs = reloj
        right.hostNowNs = reloj
        return (left, right, cableLeft, cableRight)
    }

    private func waitUntil(_ timeoutS: Double = 5, _ condition: @escaping () -> Bool) {
        let tope = Date().addingTimeInterval(timeoutS)
        while !condition(), Date() < tope { usleep(10_000) }
        XCTAssertTrue(condition())
    }

    private func isConnected(_ session: RigLinkSession) -> Bool {
        if case .connected = session.state { return true }
        return false
    }

    // MARK: - Roles (IOS-80)

    func testConElDerechoDeMaestroTodoFunciona() {
        let (left, right, cableLeft, cableRight) = makePair()
        left.claimedRole = .slave
        left.prefersMaster = false
        left.matchId = "m1"
        left.term = 2
        right.claimedRole = .master
        right.prefersMaster = true
        right.matchId = "m1"
        right.term = 2
        let lock = NSLock()
        nonisolated(unsafe) var ordenes: [RigWireCommand] = []
        left.onCommand = { c in lock.lock(); ordenes.append(c); lock.unlock() }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }
        XCTAssertTrue(right.isMaster)
        XCTAssertFalse(left.isMaster)
        // El esclavo (el izquierdo) pregunta la hora; el maestro (el derecho) contesta.
        waitUntil { !cableLeft.sentFrames(of: .clockPing).isEmpty && !cableRight.sentFrames(of: .clockPong).isEmpty }
        XCTAssertTrue(cableRight.sentFrames(of: .clockPing).isEmpty)
        // Las órdenes van del derecho al izquierdo.
        right.send(command: .record)
        left.send(command: .stop)  // el esclavo no manda
        waitUntil { lock.lock(); defer { lock.unlock() }; return ordenes == [.record] }
    }

    func testSinParCadaUnoActuaConSuPreferenciaYLoAvisa() {
        let (left, right, _, _) = makePair()
        for s in [left, right] { s.claimedRole = .slave }
        left.prefersMaster = true
        right.prefersMaster = false
        let lock = NSLock()
        nonisolated(unsafe) var roles: [String: RigRole] = [:]
        left.onRole = { r, _, _ in lock.lock(); roles["izq"] = roles["izq"] ?? r; lock.unlock() }
        right.onRole = { r, _, _ in lock.lock(); roles["der"] = roles["der"] ?? r; lock.unlock() }
        left.start()
        right.start()
        waitUntil { lock.lock(); defer { lock.unlock() }; return roles.count == 2 }
        XCTAssertEqual(roles["izq"], .master, "el que prefiere dirigir compone desde el arranque")
        XCTAssertEqual(roles["der"], .slave)
        waitUntil { self.isConnected(left) && self.isConnected(right) }
        XCTAssertTrue(left.isMaster)
        XCTAssertFalse(right.isMaster)
    }

    func testElOperadorFuerzaElRelevoEnElEsclavo() {
        // La vuelta del maestro de antes con su term viejo la cubre RoleNegotiationTests
        // (el term mayor manda); aquí, lo propio de forceMaster.
        let (left, right, _, _) = makePair()
        for s in [left, right] { s.matchId = "m1"; s.term = 1 }
        left.claimedRole = .master
        right.claimedRole = .slave
        let lock = NSLock()
        nonisolated(unsafe) var roles: [RigRole] = []
        right.onRole = { r, _, _ in lock.lock(); roles.append(r); lock.unlock() }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }
        XCTAssertFalse(right.isMaster)
        left.stop()  // cae el maestro
        nonisolated(unsafe) var nuevo: Int?
        right.forceMaster { t in lock.lock(); nuevo = t; lock.unlock() }
        waitUntil { lock.lock(); defer { lock.unlock() }; return nuevo != nil }
        XCTAssertEqual(nuevo, 2)
        XCTAssertTrue(right.isMaster)
        XCTAssertEqual(right.term, 2)
        lock.lock()
        XCTAssertEqual(roles.last, .master)
        lock.unlock()
        // Si ya dirige, no hace nada.
        nonisolated(unsafe) var otra: Int? = 99
        right.forceMaster { t in lock.lock(); otra = t; lock.unlock() }
        waitUntil { lock.lock(); defer { lock.unlock() }; return otra == nil }
        XCTAssertEqual(right.term, 2)
    }

    func testDosMaestrosDelMismoTermSeResuelvenSinQuedarseConDos() {
        let (left, right, _, _) = makePair()
        for s in [left, right] {
            s.claimedRole = .master
            s.matchId = "m1"
            s.term = 3
        }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }
        XCTAssertNotEqual(left.isMaster, right.isMaster)
        XCTAssertTrue(left.isMaster, "con el mismo term, manda el izquierdo")
    }

    func testDosMaestrosDePartidosDistintosQuedanEnConflicto() {
        let (left, right, _, _) = makePair()
        left.claimedRole = .master
        left.matchId = "m1"
        left.term = 1
        right.claimedRole = .master
        right.matchId = "m2"
        right.term = 4
        left.start()
        right.start()
        waitUntil { left.state == .conflict && right.state == .conflict }
    }

    // MARK: - El latido (IOS-81)

    func testUnCorteEnUnSoloSentidoLoVenLosDos() {
        let (left, right, cableLeft, _) = makePair()
        let real = { Int64(DispatchTime.now().uptimeNanoseconds) }
        left.hostNowNs = real
        right.hostNowNs = real
        left.start()
        right.start()
        waitUntil { left.health.state == .up && right.health.state == .up }
        // Lo que manda el izquierdo ya no llega; lo del derecho, sí.
        let inicio = Date()
        cableLeft.peer = nil
        waitUntil(3) { left.health.state == .down && right.health.state == .down }
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 1.0, "los dos lo ven en ~0,5 s")
    }

    // MARK: - El render repartido (IOS-52)

    func testVistasPartesNoPartEIdrRequestVanCadaUnoEnSuSentido() throws {
        let (left, right, cableLeft, _) = makePair()
        let lock = NSLock()
        nonisolated(unsafe) var vistas: [[ViewCommand]] = []
        nonisolated(unsafe) var partes: [PartPacket] = []
        nonisolated(unsafe) var nadas: [NoPartPacket] = []
        nonisolated(unsafe) var peticiones: [UInt32] = []
        right.onViews = { v in lock.lock(); vistas.append(v); lock.unlock() }
        left.onPart = { p, _ in lock.lock(); partes.append(p); lock.unlock() }
        left.onNoPart = { n in lock.lock(); nadas.append(n); lock.unlock() }
        right.onIdrRequest = { s in lock.lock(); peticiones.append(s); lock.unlock() }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }

        let vista = ViewWire.quantized(ViewCommand(
            targetRigMs: 1000, viewId: 5, yawRad: 0.2, pitchRad: 0, hfovRad: 1.1,
            sides: [.left, .right], seamYawRad: 0, featherRad: 0.02, gains: .unity
        ))
        let parte = PartPacket(
            partSeq: 9, frameRigMs: 1001, view: vista, extrapolated: true, isKey: true,
            accessUnit: Data(repeating: 7, count: 3000)
        )
        left.send(views: [vista])
        right.send(part: parte)
        right.send(noPart: NoPartPacket(frameRigMs: 1034, viewId: 6))
        left.requestIdr(partSeq: 10)
        // Al revés no sale nada: el esclavo no manda vistas ni el maestro partes.
        right.send(views: [vista])
        left.send(part: parte)
        waitUntil {
            lock.lock(); defer { lock.unlock() }
            return vistas.count == 1 && partes.count == 1 && nadas.count == 1 && peticiones == [10]
        }
        lock.lock()
        XCTAssertEqual(vistas.first, [vista])
        XCTAssertEqual(partes.first, parte)
        XCTAssertEqual(nadas.first, NoPartPacket(frameRigMs: 1034, viewId: 6))
        lock.unlock()
        // IOS-82: la pizarra, del maestro al esclavo.
        nonisolated(unsafe) var pizarra = Data()
        right.onReplica = { d in lock.lock(); pizarra = d; lock.unlock() }
        left.send(replica: Data("{\"version\":1}".utf8))
        waitUntil { lock.lock(); defer { lock.unlock() }; return pizarra.count == 13 }
        // IOS-73: las detecciones del esclavo, con su instante.
        nonisolated(unsafe) var detec: (Int64, [PlayerDetection])?
        left.onDetections = { t, _, d in lock.lock(); detec = (t, d); lock.unlock() }
        right.send(detections: [PlayerDetection(x1: 10, y1: 20, x2: 30, y2: 80, playerClass: .referee, score: 0.8)],
                   targetRigMs: 4000, inferMs: 12)
        waitUntil { lock.lock(); defer { lock.unlock() }; return detec?.0 == 4000 }
        lock.lock()
        XCTAssertEqual(detec?.1.first?.playerClass, .referee)
        XCTAssertEqual(detec?.1.first?.score ?? 0, 0.8, accuracy: 1.0 / 255)
        lock.unlock()
        // IOS-64: la miniatura del esclavo.
        nonisolated(unsafe) var miniatura = Data()
        left.onThumb = { d in lock.lock(); miniatura = d; lock.unlock() }
        right.send(thumb: Data(repeating: 0xD8, count: 30_000))
        waitUntil { lock.lock(); defer { lock.unlock() }; return miniatura.count == 30_000 }
        // IOS-38: las medias del solape, del esclavo al maestro.
        nonisolated(unsafe) var medias: [Double] = []
        left.onColorMeans = { m in lock.lock(); medias = m; lock.unlock() }
        right.send(colorMeans: [100, 120.5, 90])
        waitUntil { lock.lock(); defer { lock.unlock() }; return medias == [100, 120.5, 90] }
        // IOS-70: la orden de calibrar, con sus destinos.
        nonisolated(unsafe) var destinos: [Int64] = []
        right.onCalibrationCapture = { d in lock.lock(); destinos = d; lock.unlock() }
        left.send(calibrationCapture: [10_500, 11_500])
        right.send(calibrationCapture: [1])  // el esclavo no la manda
        waitUntil { lock.lock(); defer { lock.unlock() }; return destinos == [10_500, 11_500] }
        let enviada = try XCTUnwrap(cableLeft.sentFrames(of: .idrRequest).first)
        XCTAssertEqual(IdrRequestWire.decode(enviada.payload), 10)
        XCTAssertTrue(cableLeft.sentFrames(of: .part).isEmpty)
    }

    // MARK: - La escalera (IOS-06, IOS-25)

    func testLaEscaleraDelEsclavoVaEnSuLatidoYLaCadenciaComunEnUnaOrden() throws {
        let (left, right, cableLeft, cableRight) = makePair()
        let lock = NSLock()
        nonisolated(unsafe) var oidosEnElMaestro: [UInt8] = []
        nonisolated(unsafe) var ordenes: [CadenceCommand] = []
        left.onPeerLadder = { n in lock.lock(); oidosEnElMaestro.append(n); lock.unlock() }
        right.onCadence = { c in lock.lock(); ordenes.append(c); lock.unlock() }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }

        // El primer latido trae el nivel (0); el cambio a L2, una vez, aunque lleguen diez.
        waitUntil { lock.lock(); defer { lock.unlock() }; return oidosEnElMaestro == [0] }
        right.setLadderLevel(2)
        waitUntil { lock.lock(); defer { lock.unlock() }; return oidosEnElMaestro == [0, 2] }
        usleep(300_000)
        lock.lock()
        XCTAssertEqual(oidosEnElMaestro, [0, 2], "solo los cambios")
        lock.unlock()

        // El maestro fija la común; el esclavo no manda órdenes.
        left.send(cadence: CadenceCommand(level: .l2))
        right.send(cadence: CadenceCommand(level: .l4))
        waitUntil { lock.lock(); defer { lock.unlock() }; return ordenes == [CadenceCommand(level: .l2)] }
        XCTAssertTrue(cableRight.sentFrames(of: .command).isEmpty)
        let enviada = try XCTUnwrap(cableLeft.sentFrames(of: .command).first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: enviada.payload) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "cadence")
        XCTAssertEqual(json["level"] as? Int, 2)
        XCTAssertEqual(json["ai"] as? Bool, false)
    }

    // MARK: - Apretón

    func testTheSameSecretConnectsBothSides() {
        let (left, right, _, _) = makePair()
        left.start()
        right.start()

        waitUntil { self.isConnected(left) && self.isConnected(right) }
        if case let .connected(peer) = left.state {
            XCTAssertEqual(peer, "iphone-der")
        }
    }

    func testAWrongSecretRejectsAndAsksToPairAgain() {
        let (left, right, _, _) = makePair(rightSecret: Data(repeating: 0x44, count: 32))
        left.start()
        right.start()

        waitUntil {
            if case .rejected = left.state { return true }
            return false
        }
        if case let .rejected(motivo) = left.state {
            XCTAssertTrue(motivo.contains("secreto"))
        }
        XCTAssertFalse(isConnected(right))
    }

    func testBothSayingTheSameSideIsRejected() {
        let (left, right, _, _) = makePair(rightSide: .left)
        left.start()
        right.start()

        waitUntil {
            if case .rejected = left.state { return true }
            return false
        }
        if case let .rejected(motivo) = left.state {
            XCTAssertTrue(motivo.contains("left"))
        }
    }

    // MARK: - El reloj

    func testOnlyTheSlaveAsksTheTimeAndStampsFlowBack() {
        let (left, right, cableLeft, cableRight) = makePair()
        nonisolated(unsafe) var sellos: [(Int64, Int64, Int64, Int64)] = []
        let lock = NSLock()
        right.onStamps = { t1, t2, t3, t4 in
            lock.lock()
            sellos.append((t1, t2, t3, t4))
            lock.unlock()
        }
        left.start()
        right.start()
        waitUntil { self.isConnected(right) }

        // La ráfaga va a 250 ms: en un segundo tiene que haber al menos dos vueltas.
        waitUntil(3) {
            lock.lock()
            defer { lock.unlock() }
            return sellos.count >= 2
        }
        XCTAssertGreaterThanOrEqual(cableRight.sentFrames(of: .clockPing).count, 2)
        XCTAssertGreaterThanOrEqual(cableLeft.sentFrames(of: .clockPong).count, 2)
        // El maestro jamás pregunta.
        XCTAssertEqual(cableLeft.sentFrames(of: .clockPing).count, 0)
        // Los sellos crecen: t1 < t2 ≤ t3 < t4 con el reloj inyectado.
        lock.lock()
        let (t1, t2, t3, t4) = sellos[0]
        lock.unlock()
        XCTAssertLessThan(t1, t2)
        XCTAssertLessThanOrEqual(t2, t3)
        XCTAssertLessThan(t3, t4)
    }

    func testARepeatedMediaFrameIsIgnored() {
        let (left, right, cableLeft, cableRight) = makePair()
        nonisolated(unsafe) var sellos = 0
        let lock = NSLock()
        right.onStamps = { _, _, _, _ in
            lock.lock()
            sellos += 1
            lock.unlock()
        }
        left.start()
        right.start()
        waitUntil(3) {
            lock.lock()
            defer { lock.unlock() }
            return sellos >= 1
        }

        // El mismo pong, otra vez: la ventana lo tira.
        let pong = cableLeft.sentFrames(of: .clockPong).first!
        lock.lock()
        let antes = sellos
        lock.unlock()
        cableRight.onFrame?(pong, .media)
        usleep(200_000)
        lock.lock()
        let despues = sellos
        lock.unlock()
        XCTAssertEqual(despues, antes)
    }

    // MARK: - El reloj tras un relevo (ADR 0023 §4, enmienda del 2026-10-11)

    /// Lo que separa los relojes de host de los dos iPhone: lo medido en la pasada de
    /// SPK-04 (`bench/dos-moviles-20261011-1506`), en ns.
    private static let hostGapNs: Int64 = 591_898 * 1_000_000_000
    /// Lo que se le pide a una estimación con el reloj inyectado, en ns: muy por encima del
    /// error del contador (decenas de ns) y muy por debajo de un cambio de dominio.
    private static let clockToleranceNs: Int64 = 1_000_000

    /// Un par con relojes de host distintos: el derecho va `hostGapNs` por delante. Devuelve
    /// también el instante «de verdad», que es el host del izquierdo.
    private func makePairWithHostGap()
        -> (left: RigLinkSession, right: RigLinkSession, cableLeft: FakeLinkTransport,
            cableRight: FakeLinkTransport, now: () -> Int64)
    {
        let (left, right, cableLeft, cableRight) = makePair()
        let lock = NSLock()
        nonisolated(unsafe) var t = Int64(1_000)
        let verdad: () -> Int64 = {
            lock.lock()
            defer { lock.unlock() }
            t += 10
            return t
        }
        left.hostNowNs = verdad
        right.hostNowNs = { verdad() + Self.hostGapNs }
        return (left, right, cableLeft, cableRight, verdad)
    }

    func testSinRelevoElMaestroContestaConSuHostYElEsclavoCaeEnEl() {
        // Un maestro que nunca fue esclavo no tiene muestras: su reloj del soporte es su
        // host, y el pong sale igual que antes de la enmienda.
        let (left, right, _, _, _) = makePairWithHostGap()
        nonisolated(unsafe) var sellos: [(Int64, Int64, Int64, Int64)] = []
        let lock = NSLock()
        right.onStamps = { t1, t2, t3, t4 in lock.lock(); sellos.append((t1, t2, t3, t4)); lock.unlock() }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }
        waitUntil(3) { right.clock.estimate != nil }

        XCTAssertTrue(left.isMaster)
        XCTAssertTrue(left.clock.samples.isEmpty, "el maestro no alimenta su reloj")
        lock.lock()
        let vistos = sellos
        lock.unlock()
        for (t1, t2, t3, t4) in vistos {
            // t2 y t3 en el host del izquierdo: entre la salida y la llegada del esclavo,
            // pasadas a ese host.
            XCTAssertLessThan(t1 - Self.hostGapNs, t2)
            XCTAssertLessThanOrEqual(t2, t3)
            XCTAssertLessThan(t3, t4 - Self.hostGapNs)
        }
        let desfase = right.clock.offsetAt(ns: right.hostNowNs())
        XCTAssertLessThan(abs(desfase + Self.hostGapNs), Self.clockToleranceNs)
    }

    func testTrasUnRelevoElMaestroDeAntesSeSincronizaAlSoporteYNoAlHostDelPromovido() {
        // A (izquierdo) maestro y B (derecho) esclavo sincronizado; cae A, B se promueve; A
        // vuelve y queda de esclavo. Su reloj del soporte tiene que ser el de B, que sigue el
        // dominio de A, y no el host de B (+591 898 s: lo que pasaba antes de la enmienda).
        let (a, b, _, cableB, ahora) = makePairWithHostGap()
        for s in [a, b] { s.matchId = "m1"; s.term = 1 }
        a.claimedRole = .master
        b.claimedRole = .slave
        a.start()
        b.start()
        waitUntil { self.isConnected(a) && self.isConnected(b) }
        waitUntil(3) { b.clock.estimate != nil }
        XCTAssertLessThan(abs(b.clock.offsetAt(ns: b.hostNowNs()) + Self.hostGapNs), Self.clockToleranceNs)

        // Cae A: B lo ve en su transporte y el operador pulsa «Este móvil dirige».
        a.stop()
        cableB.onState?(.listening)
        waitUntil { b.state == .searching && a.state == .off }
        let lock = NSLock()
        nonisolated(unsafe) var nuevo: Int?
        b.forceMaster { t in lock.lock(); nuevo = t; lock.unlock() }
        waitUntil { lock.lock(); defer { lock.unlock() }; return nuevo != nil }
        XCTAssertTrue(b.isMaster)
        let congeladas = b.clock.samples.count

        // Vuelve el enlace: B saluda primero y A, al arrancar, recibe su hello.
        cableB.start()
        waitUntil { b.state == .authenticating }
        a.start()
        waitUntil { self.isConnected(a) && self.isConnected(b) }
        XCTAssertTrue(b.isMaster, "el term mayor manda")
        XCTAssertFalse(a.isMaster)
        XCTAssertEqual(a.term, 2)
        waitUntil(3) { a.clock.estimate != nil }

        let c = ahora()
        let soporteEnA = a.clock.toRigTimeNs(c)
        let soporteEnB = b.clock.toRigTimeNs(c + Self.hostGapNs)
        XCTAssertLessThan(abs(soporteEnA - soporteEnB), Self.clockToleranceNs,
                          "A y B en el mismo reloj del soporte")
        XCTAssertLessThan(abs(a.clock.offsetAt(ns: c)), Self.clockToleranceNs,
                          "el soporte sigue en el dominio de A: sin la enmienda saldrían +591 898 s")
        XCTAssertEqual(b.clock.samples.count, congeladas, "la recta del promovido sigue congelada")
    }

    // MARK: - PTS y órdenes

    func testPtsComeFromTheMasterOrTimeOutToEmpty() {
        let (left, right, _, cableRight) = makePair()
        left.recentPts = { [11, 22, 33] }
        left.start()
        right.start()
        waitUntil { self.isConnected(right) }

        let llegan = expectation(description: "pts")
        right.masterRecentPts { pts in
            XCTAssertEqual(pts, [11, 22, 33])
            llegan.fulfill()
        }
        wait(for: [llegan], timeout: 5)

        // Con el cable cortado, el plazo vence a vacío.
        cableRight.peer = nil
        let vacio = expectation(description: "timeout")
        right.masterRecentPts { pts in
            XCTAssertEqual(pts, [])
            vacio.fulfill()
        }
        wait(for: [vacio], timeout: 5)
    }

    func testCommandsOnlyTravelFromTheMaster() {
        let (left, right, _, cableRight) = makePair()
        nonisolated(unsafe) var recibidas: [RigWireCommand] = []
        let lock = NSLock()
        right.onCommand = { command in
            lock.lock()
            recibidas.append(command)
            lock.unlock()
        }
        left.start()
        right.start()
        waitUntil { self.isConnected(left) && self.isConnected(right) }

        right.send(command: .record)  // el esclavo no manda: se ignora
        left.send(command: .stop)

        waitUntil(3) {
            lock.lock()
            defer { lock.unlock() }
            return recibidas == [.stop]
        }
        let legados = cableRight.sentFrames(of: .legacy)
        XCTAssertTrue(legados.allSatisfy { RigMessage.decode($0.payload).map {
            if case .command = $0 { return false } else { return true }
        } ?? true }, "el esclavo no manda órdenes")
    }
}
