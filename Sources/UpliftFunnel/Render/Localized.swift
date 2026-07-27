import Foundation

// Localization resolution for the primitive-tree renderer (Spec v2 §6.5),
// ported from the Flutter SDK's `localized.dart`.
//
// A LocalizedString is either a plain string (constant across languages) or
// a `{ "key": "..." }` object that looks up into the flow's `localizations`
// catalog. Resolution is **resolve-then-interpolate**: first the locale
// lookup with fallback, then `{{var}}` interpolation.

/// Resolves a LocalizedString value to a final display string.
///
/// Order (per spec §6.5.3):
///   1. plain string → passthrough
///   2. `{key}` → localizations[locale][key]
///                 ?? localizations[defaultLocale][key]
///                 ?? key            (last resort: show the raw key)
///   3. interpolate `{{var}}` against `vars`
public func resolveString(
    _ ls: JSONValue,
    locale: String,
    localizations: JSONValue,
    defaultLocale: String,
    vars: [String: String]
) -> String {
    let s: String
    if let plain = ls.stringValue {
        s = plain
    } else if let key = ls["key"].stringValue {
        s = localizations[locale][key].stringValue
            ?? localizations[defaultLocale][key].stringValue
            ?? key
    } else {
        s = ""
    }
    return interpolate(s, vars: vars)
}

private let interpolationPattern = try! NSRegularExpression(
    pattern: #"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)*)\s*\}\}"#)

/// Replaces `{{var}}` occurrences with `vars` values.
///
/// Dotted names are part of the vocabulary — product tokens like
/// `{{price.yearly_pro}}` are injected at session start — so the pattern
/// spans segments rather than stopping at the first dot.
///
/// An unresolved token renders as an empty string (leaking template syntax
/// to end users is worse than blank).
func interpolate(_ input: String, vars: [String: String]) -> String {
    guard input.contains("{{") else { return input }
    var result = ""
    var lastEnd = input.startIndex
    let range = NSRange(input.startIndex..., in: input)
    for m in interpolationPattern.matches(in: input, range: range) {
        guard let full = Range(m.range, in: input),
              let nameRange = Range(m.range(at: 1), in: input) else { continue }
        result += input[lastEnd..<full.lowerBound]
        result += displayValue(vars[String(input[nameRange])] ?? "")
        lastEnd = full.upperBound
    }
    result += input[lastEnd...]
    return result
}

/// A multi-select writes its variable JSON-encoded (`["a","b"]`). Copy that
/// interpolates one must read as a list, not leak the array literal — so
/// decode and join. Anything else passes through.
func displayValue(_ raw: String) -> String {
    guard raw.hasPrefix("["), let data = raw.data(using: .utf8),
          let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return raw }
    return decoded.map { String(describing: $0) }.joined(separator: ", ")
}
