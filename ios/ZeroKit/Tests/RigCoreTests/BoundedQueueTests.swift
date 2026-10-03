import XCTest

@testable import RigCore

final class BoundedQueueTests: XCTestCase {
    func testFifoWithinCapacity() {
        var cola = BoundedQueue<Int>(capacity: 3)
        cola.push(1)
        cola.push(2)
        XCTAssertEqual(cola.pop(), 1)
        XCTAssertEqual(cola.pop(), 2)
        XCTAssertNil(cola.pop())
        XCTAssertEqual(cola.pushed, 2)
        XCTAssertEqual(cola.popped, 2)
        XCTAssertEqual(cola.dropped, 0)
    }

    func testDropOldestKeepsTheFreshest() {
        var cola = BoundedQueue<Int>(capacity: 2, policy: .dropOldest)
        cola.push(1)
        cola.push(2)
        let tirado = cola.push(3)

        XCTAssertEqual(tirado, 1)
        XCTAssertEqual(cola.pop(), 2)
        XCTAssertEqual(cola.pop(), 3)
        XCTAssertEqual(cola.dropped, 1)
    }

    func testDropNewestRefusesTheArrival() {
        var cola = BoundedQueue<Int>(capacity: 2, policy: .dropNewest)
        cola.push(1)
        cola.push(2)
        let tirado = cola.push(3)

        XCTAssertEqual(tirado, 3)
        XCTAssertEqual(cola.pop(), 1)
        XCTAssertEqual(cola.pop(), 2)
        XCTAssertEqual(cola.dropped, 1)
    }

    func testCountersAreExactUnderChurn() {
        var cola = BoundedQueue<Int>(capacity: 4, policy: .dropOldest)
        var sacados = 0
        for valor in 0..<1000 {
            cola.push(valor)
            if valor % 3 == 0, cola.pop() != nil { sacados += 1 }
        }
        while cola.pop() != nil { sacados += 1 }

        XCTAssertEqual(cola.pushed, 1000)
        XCTAssertEqual(cola.popped, sacados)
        XCTAssertEqual(cola.pushed, cola.popped + cola.dropped)
        XCTAssertTrue(cola.isEmpty)
    }

    func testRemoveAllResetsContentsButNotHistory() {
        var cola = BoundedQueue<Int>(capacity: 2)
        cola.push(1)
        cola.push(2)
        cola.removeAll()

        XCTAssertTrue(cola.isEmpty)
        XCTAssertNil(cola.pop())
        XCTAssertEqual(cola.pushed, 2)
    }
}
