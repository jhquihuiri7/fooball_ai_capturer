import XCTest

@testable import RigCore

/// La cola del publicador del programa (IOS-56): acotada a ~1 s, y ante congestión tira
/// hasta el siguiente IDR y lo pide.
final class ProgramSendQueueTests: XCTestCase {
    private func video(_ ms: Double, key: Bool = false) -> ProgramUnit {
        ProgramUnit(kind: .video(keyframe: key), payload: Data([key ? 5 : 1]), rigMs: ms)
    }

    private func audio(_ ms: Double) -> ProgramUnit {
        ProgramUnit(kind: .audio, payload: Data([0xA]), rigMs: ms)
    }

    func testStartsAtAnIdrAndTheAudioWaitsWithTheVideo() {
        var q = ProgramSendQueue()
        XCTAssertTrue(q.waitingForIdr)
        XCTAssertFalse(q.push(audio(0), nowMs: 0))
        XCTAssertFalse(q.push(video(33), nowMs: 33))
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.counts.audioDropped, 1)
        XCTAssertEqual(q.counts.videoDropped, 1)
        XCTAssertFalse(q.push(video(66, key: true), nowMs: 66))
        XCTAssertFalse(q.push(audio(70), nowMs: 70))
        XCTAssertEqual(q.pop(), video(66, key: true))
        XCTAssertEqual(q.pop(), audio(70))
        XCTAssertNil(q.pop())
        XCTAssertEqual(q.counts.congestions, 0)
    }

    func testAQueueThatDrainsNeverDrops() {
        // 10 min de programa: 30 fotogramas y ~47 tramas por segundo, enviados al llegar.
        var q = ProgramSendQueue()
        _ = q.push(video(0, key: true), nowMs: 0)
        _ = q.pop()
        for i in 1..<18_000 {
            let t = Double(i) * 1000 / 30
            XCTAssertFalse(q.push(video(t, key: i % 60 == 0), nowMs: t))
            XCTAssertFalse(q.push(audio(t), nowMs: t))
            while q.pop() != nil {}
        }
        XCTAssertEqual(q.counts, .init())
    }

    func testMoreThanOneSecondWaitingDropsEverythingAndAsksForAnIdr() {
        var q = ProgramSendQueue()
        _ = q.push(video(0, key: true), nowMs: 0)
        var pedidos = 0
        // SRT no deja salir nada: a los 1000 ms de espera la cola se da por congestionada.
        for i in 1...31 {
            let t = Double(i) * 1000 / 30
            if q.push(video(t), nowMs: t) { pedidos += 1 }
            if q.push(audio(t), nowMs: t) { pedidos += 1 }
        }
        XCTAssertEqual(pedidos, 1)
        XCTAssertTrue(q.waitingForIdr)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.counts.congestions, 1)
        XCTAssertEqual(q.counts.idrRequests, 1)
        XCTAssertEqual(q.counts.videoDropped, 32)  // el IDR y 31 P: el 31.º desbordó
        XCTAssertEqual(q.counts.audioDropped, 31)  // 30 en la cola y el último, ya esperando

        // Lo que llega hasta el IDR se tira sin volver a pedirlo; el IDR lo arregla.
        XCTAssertFalse(q.push(video(1100), nowMs: 1100))
        XCTAssertFalse(q.push(video(1133, key: true), nowMs: 1133))
        XCTAssertFalse(q.waitingForIdr)
        XCTAssertEqual(q.pop(), video(1133, key: true))
    }

    func testAnIdrThatOverflowsIsKept() {
        var q = ProgramSendQueue(maxWaitMs: 1000, maxUnits: 160)
        _ = q.push(video(0, key: true), nowMs: 0)
        for i in 1..<30 { _ = q.push(video(Double(i) * 33), nowMs: Double(i) * 33) }
        // El IDR natural del GOP llega justo cuando desborda: se sigue desde él.
        XCTAssertFalse(q.push(video(1010, key: true), nowMs: 1010))
        XCTAssertFalse(q.waitingForIdr)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.peek(), video(1010, key: true))
        XCTAssertEqual(q.counts.congestions, 1)
        XCTAssertEqual(q.counts.idrRequests, 0)
    }

    func testTheUnitCapHoldsEvenIfTheClockStops() {
        var q = ProgramSendQueue(maxWaitMs: 1000, maxUnits: 4)
        _ = q.push(video(0, key: true), nowMs: 0)
        for i in 1...3 { XCTAssertFalse(q.push(audio(Double(i)), nowMs: 0)) }
        XCTAssertTrue(q.push(audio(4), nowMs: 0))
        XCTAssertTrue(q.isEmpty)
    }

    func testDropUntilIdrFromOutsideAsksOnce() {
        // SRT cortó un fotograma a medias: lo que queda en la cola ya no sirve.
        var q = ProgramSendQueue()
        _ = q.push(video(0, key: true), nowMs: 0)
        _ = q.push(audio(10), nowMs: 10)
        XCTAssertTrue(q.dropUntilIdr())
        XCTAssertFalse(q.dropUntilIdr(), "ya se está esperando: no se pide otro")
        XCTAssertEqual(q.counts.idrRequests, 1)
        XCTAssertEqual(q.counts.congestions, 2)
        XCTAssertEqual(q.counts.videoDropped, 1)
        XCTAssertEqual(q.counts.audioDropped, 1)
    }

    func testRestartingForANewConnectionIsNotACongestion() {
        var q = ProgramSendQueue()
        _ = q.push(video(0, key: true), nowMs: 0)
        q.restart()
        XCTAssertTrue(q.isEmpty)
        XCTAssertTrue(q.waitingForIdr)
        XCTAssertEqual(q.counts.congestions, 0)
        XCTAssertEqual(q.oldestWaitMs(nowMs: 500), 0)
    }

    func testReconnectEveryThreeSecondsAndBackOffOnlyOnRejections() {
        var b = ReconnectBackoff()
        XCTAssertEqual(b.delayS(after: .unreachable), 3)
        XCTAssertEqual(b.delayS(after: .lost), 3)
        XCTAssertEqual([b.delayS(after: .rejected), b.delayS(after: .rejected), b.delayS(after: .rejected),
                        b.delayS(after: .rejected), b.delayS(after: .rejected), b.delayS(after: .rejected)],
                       [3, 6, 12, 24, 30, 30])
        // Un corte de red entre rechazos sigue a los 3 s: la red puede volver ya.
        XCTAssertEqual(b.delayS(after: .unreachable), 3)
        b.connected()
        XCTAssertEqual(b.delayS(after: .rejected), 3)
    }
}
