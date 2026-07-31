import Foundation

/// `JSONValue` → plain Foundation objects, for the layout target.
///
/// `UpliftLayout` may not import this module — it is the platform-free core
/// that Dart and Kotlin will be ports of — so it reads the shape every JSON
/// decoder on every platform already produces: dictionaries, arrays, strings
/// and `NSNumber`. This is the one place the SDK's own representation is
/// converted to it.
///
/// One conversion per screen render, on trees of a few hundred nodes. Worth
/// measuring before optimising, and worth keeping simple until then: the
/// alternative is a second decoder, and two decoders drift.
extension JSONValue {
    var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let b):
            // NSNumber, not Bool, so a `as? Bool` cast on the far side keeps
            // working — Foundation's JSON gives NSNumber for both and the
            // decoder was written against that.
            return NSNumber(value: b)
        case .number(let n):
            return NSNumber(value: n)
        case .string(let s):
            return s
        case .array(let items):
            return items.map(\.foundationObject)
        case .object(let fields):
            return fields.mapValues(\.foundationObject)
        }
    }

    /// The flow as the v3 decoder wants it.
    public var flowDictionary: [String: Any] {
        foundationObject as? [String: Any] ?? [:]
    }
}
