// Accesores cómodos sobre GoldenValue (IOS-30): leer entradas de un caso sin
// ahogarse en pattern matching. Lanzan con el nombre del campo, como el servidor.

import Foundation

extension GoldenValue {
    var numberValue: Double? {
        if case let .number(valor) = self { return valor }
        return nil
    }

    var stringValue: String? {
        if case let .string(valor) = self { return valor }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(valor) = self { return valor }
        return nil
    }

    var objectValue: [String: GoldenValue]? {
        if case let .object(valor) = self { return valor }
        return nil
    }

    var tensorValue: GoldenTensor? {
        if case let .tensor(valor) = self { return valor }
        return nil
    }

    func field(_ clave: String) throws -> GoldenValue {
        guard let objeto = objectValue, let valor = objeto[clave] else {
            throw GoldenError.message("falta el campo \(clave)")
        }
        return valor
    }

    func number(_ clave: String) throws -> Double {
        guard let valor = try field(clave).numberValue else {
            throw GoldenError.message("\(clave) no es un número")
        }
        return valor
    }

    func string(_ clave: String) throws -> String {
        guard let valor = try field(clave).stringValue else {
            throw GoldenError.message("\(clave) no es una cadena")
        }
        return valor
    }

    /// El JSON plano equivalente, para los códecs que leen [String: Any].
    func jsonObject() -> Any {
        switch self {
        case .null: return NSNull()
        case let .bool(valor): return valor
        case let .number(valor):
            return valor == valor.rounded() && abs(valor) < 1e15 ? Int(valor) : valor
        case let .string(valor): return valor
        case let .array(valores): return valores.map { $0.jsonObject() }
        case let .object(valores): return valores.mapValues { $0.jsonObject() }
        case let .tensor(tensor): return ["dtype": tensor.dtype, "shape": tensor.shape]
        }
    }

    /// Un GoldenValue desde JSON plano, para comparar códecs (toDictionary).
    static func from(json: Any) -> GoldenValue {
        switch json {
        case is NSNull: return .null
        case let valor as Bool: return .bool(valor)
        case let valor as Int: return .number(Double(valor))
        case let valor as Double: return .number(valor)
        case let valor as String: return .string(valor)
        case let valores as [Any]: return .array(valores.map { from(json: $0) })
        case let valores as [String: Any]: return .object(valores.mapValues { from(json: $0) })
        default: return .null
        }
    }

    /// Un tensor f64 construido desde Swift, para comparar contra el esperado.
    static func tensor(f64 valores: [Double], shape: [Int]) -> GoldenValue {
        var data = Data(capacity: valores.count * 8)
        for valor in valores {
            var le = valor.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return .tensor(GoldenTensor(dtype: "f64", shape: shape, data: data))
    }

    static func tensor(i32 valores: [Int32], shape: [Int]) -> GoldenValue {
        var data = Data(capacity: valores.count * 4)
        for valor in valores {
            var le = valor.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return .tensor(GoldenTensor(dtype: "i32", shape: shape, data: data))
    }

    static func tensor(u8 valores: [UInt8], shape: [Int]) -> GoldenValue {
        .tensor(GoldenTensor(dtype: "u8", shape: shape, data: Data(valores)))
    }
}
