import Foundation

// Condition evaluation, shared by the flow engine (transition rules) and the
// renderer (a button's `enabled_when` gate). Both ask the same question —
// "does the current state satisfy this rule?" — so they must answer it
// identically: a CTA that looks tappable while the transition behind it would
// refuse to fire is a dead end for the user.

/// Reads a variable by name. Dotted names are context paths
/// (`device.platform`), bare names are flow variables. `nil` (or `.null`)
/// means "not set".
public typealias VariableReader = (String) -> JSONValue?

/// Evaluates `c` against the values `read` returns.
///
/// A comparison against a non-numeric operand throws `FlowEngineError`; the
/// caller decides whether that's fatal (transitions) or should degrade
/// (rendering, where an author's typo shouldn't blank the screen).
public func evaluateCondition(_ c: FunnelCondition, read: VariableReader) throws -> Bool {
    let value = normalized(read(c.varName))
    let operand = normalized(c.value)

    switch c.op {
    case .isSet:
        return value != nil
    case .isNotSet:
        return value == nil
    case .eq:
        return looseEquals(value, operand)
    case .neq:
        return !looseEquals(value, operand)
    case .gt:
        return try compareNum(value, operand) > 0
    case .lt:
        return try compareNum(value, operand) < 0
    case .gte:
        return try compareNum(value, operand) >= 0
    case .lte:
        return try compareNum(value, operand) <= 0
    case .contains:
        return containsValue(value, operand)
    case .notContains:
        return !containsValue(value, operand)
    }
}

/// JSON `null` and a missing variable are the same thing for conditions.
private func normalized(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
}

func looseEquals(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
    guard let a, let b else { return (a == nil) == (b == nil) }
    if case .number(let na) = a, case .number(let nb) = b { return na == nb }
    return looseString(a) == looseString(b)
}

func compareNum(_ a: JSONValue?, _ b: JSONValue?) throws -> Int {
    guard let na = asNum(a), let nb = asNum(b) else {
        throw FlowEngineError(
            "Comparison op requires numeric operands; got "
            + "\(a?.serializedString() ?? "null") and \(b?.serializedString() ?? "null")")
    }
    if na < nb { return -1 }
    if na > nb { return 1 }
    return 0
}

/// Number, or a numeric string — the analog of Dart's `asNum`.
func asNum(_ v: JSONValue?) -> Double? {
    v?.doubleValue
}

func containsValue(_ haystack: JSONValue?, _ needle: JSONValue?) -> Bool {
    guard let haystack, let needle else { return false }
    if let list = haystack.arrayValue {
        return list.contains { $0 == needle }
    }
    if let hay = haystack.stringValue, let sub = needle.stringValue {
        return hay.contains(sub)
    }
    return false
}

/// Dart-`toString()`-style rendering used by `looseEquals` when either side
/// isn't a number: scalars render plainly, containers via their JSON form.
private func looseString(_ v: JSONValue) -> String {
    v.stringifiedValue ?? v.serializedString()
}
