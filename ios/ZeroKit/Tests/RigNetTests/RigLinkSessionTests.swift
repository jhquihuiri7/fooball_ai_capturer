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
