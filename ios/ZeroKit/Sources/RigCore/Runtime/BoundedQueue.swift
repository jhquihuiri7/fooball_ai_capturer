// Cola acotada (IOS-04): la regla del servidor, en Swift.
//
// Ante saturación se descarta, nunca se encola sin límite (CLAUDE.md §2 de football-ai):
// una cola que crece es latencia que nadie pidió y memoria que el jetsam cobra después.
// El anillo es de capacidad fija y los descartes se cuentan, porque un descarte no es un
// error pero sí una medida: la telemetría de IOS-05 los publica.
//
// No sincroniza: quien la usa decide el cerrojo (o la cola de despacho) que le toca.

import Foundation

/// Qué se tira cuando la cola está llena.
public enum BoundedQueuePolicy: Sendable {
    /// Se tira el más viejo: lo normal con frames, donde lo último es lo que vale.
    case dropOldest
    /// Se tira el nuevo: para trabajos que, una vez aceptados, hay que terminar.
    case dropNewest
}

public struct BoundedQueue<Element> {
    private var slots: [Element?]
    private var head = 0
    private var filled = 0

    public let capacity: Int
    public let policy: BoundedQueuePolicy

    /// Cuentas exactas, para la telemetría: lo que entró, lo que salió y lo tirado.
    public private(set) var pushed = 0
    public private(set) var popped = 0
    public private(set) var dropped = 0

    public init(capacity: Int, policy: BoundedQueuePolicy = .dropOldest) {
        precondition(capacity >= 1, "una cola sin hueco no es una cola")
        self.capacity = capacity
        self.policy = policy
        slots = Array(repeating: nil, count: capacity)
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }
    public var isFull: Bool { filled == capacity }

    /// Encola. Devuelve el elemento que se tiró, si la política tiró alguno.
    @discardableResult
    public mutating func push(_ element: Element) -> Element? {
        pushed += 1
        if filled < capacity {
            slots[(head + filled) % capacity] = element
            filled += 1
            return nil
        }
        dropped += 1
        switch policy {
        case .dropNewest:
            return element
        case .dropOldest:
            let victim = slots[head]
            slots[head] = element
            head = (head + 1) % capacity
            return victim
        }
    }

    public mutating func pop() -> Element? {
        guard filled > 0 else { return nil }
        let element = slots[head]
        slots[head] = nil
        head = (head + 1) % capacity
        filled -= 1
        popped += 1
        return element
    }

    /// Vacía sin contar descartes: es un reinicio, no una saturación.
    public mutating func removeAll() {
        slots = Array(repeating: nil, count: capacity)
        head = 0
        filled = 0
    }
}
