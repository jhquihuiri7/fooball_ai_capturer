// La ventana contra repeticiones del canal de medios (IOS-16, ADR 0023 §3).
//
// Por UDP los `seq` llegan desordenados y eso es normal: se aceptan dentro de una
// ventana de 64. Lo que queda por detrás se tira, para que nadie pueda repetir una
// trama vieja; un duplicado dentro de la ventana también se tira. Es el esquema
// clásico de IPsec, en pequeño.

import Foundation

public struct ReplayWindow: Sendable {
    public static let defaultSpan: UInt32 = 64

    private let span: UInt32
    private var highest: UInt32?
    private var seen: UInt64 = 0  // bit i = (highest − i) ya visto

    public private(set) var accepted = 0
    public private(set) var rejectedOld = 0
    public private(set) var rejectedDuplicate = 0

    public init(span: UInt32 = ReplayWindow.defaultSpan) {
        precondition(span >= 1 && span <= 64, "la ventana cabe en un u64")
        self.span = span
    }

    /// `true` si la trama con este `seq` se acepta. Muta el estado solo al aceptar.
    public mutating func accept(_ seq: UInt32) -> Bool {
        guard let top = highest else {
            highest = seq
            seen = 1
            accepted += 1
            return true
        }
        if seq > top {
            let shift = seq - top
            seen = shift >= 64 ? 1 : (seen << UInt64(shift)) | 1
            highest = seq
            accepted += 1
            return true
        }
        let behind = top - seq
        guard behind < span else {
            rejectedOld += 1
            return false
        }
        let bit: UInt64 = 1 << UInt64(behind)
        guard seen & bit == 0 else {
            rejectedDuplicate += 1
            return false
        }
        seen |= bit
        accepted += 1
        return true
    }
}
