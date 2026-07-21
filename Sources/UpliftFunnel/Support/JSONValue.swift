import Foundation

/// Dynamic JSON value used everywhere the SDK touches wire payloads.
///
/// The serving contract is forward-compatible: unknown node types render a
/// placeholder and unknown props ride along ignored. That rules out rigid
/// `Codable` structs — this enum mirrors the Flutter SDK's fully dynamic
/// `Map<String, dynamic>` parsing, with forgiving typed accessors.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let d):
            // Encode whole numbers without a fractional part so wire payloads
            // stay clean (timestamps, counts).
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d >= -9_007_199_254_740_991, d <= 9_007_199_254_740_991 {
                try container.encode(Int64(d))
            } else {
                try container.encode(d)
            }
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}

// MARK: - Parsing / serialization helpers

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    public func serializedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func serializedString() -> String {
        guard let data = try? serializedData() else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Typed accessors (forgiving, Flutter-parity)

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// String iff the value is a JSON string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Scalar rendered as a string (string/number/bool) — the analog of
    /// Dart's `value.toString()` used when stringifying variables.
    public var stringifiedValue: String? {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d.truncatingRemainder(dividingBy: 1) == 0, abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        default: return nil
        }
    }

    /// Number, also parsing numeric strings — the analog of Dart's `asNum`.
    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.truncatingRemainder(dividingBy: 1) == 0,
              d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Missing keys / non-objects resolve to `.null` so lookups chain safely.
    public subscript(key: String) -> JSONValue {
        objectValue?[key] ?? .null
    }

    public subscript(index: Int) -> JSONValue {
        guard let a = arrayValue, index >= 0, index < a.count else { return .null }
        return a[index]
    }
}

// MARK: - Foundation bridging

extension JSONValue {
    /// Builds a JSONValue from a Foundation JSON object graph.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let v as JSONValue:
            self = v
        case let b as Bool:
            self = .bool(b)
        case let n as NSNumber:
            // NSNumber bools are handled above via the Bool cast on Darwin
            // only when bridged; double-check the objCType to be safe.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let i as Int:
            self = .number(Double(i))
        case let d as Double:
            self = .number(d)
        case let s as String:
            self = .string(s)
        case let a as [Any?]:
            self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any?]:
            self = .object(o.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }

    /// Converts back to a Foundation JSON object graph (`nil` for `.null`).
    public var anyValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .number(let d):
            if d.truncatingRemainder(dividingBy: 1) == 0, abs(d) < 9e15 {
                return Int64(d)
            }
            return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue as Any }
        case .object(let o): return o.mapValues { $0.anyValue as Any }
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
