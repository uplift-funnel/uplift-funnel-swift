/// What a screen does when it is touched.
///
/// A sibling to `DisplayList` and built the same way, for the same reason: the
/// tree is walked once, the answers are turned into data, and everything after
/// that is a lookup. A view holding this needs no knowledge of the document
/// format, and the rules — which node claims a tap, what a group does with a
/// value, whether an answer advances the screen — are unit-testable without a
/// touch or a run loop.
///
/// v3's whole interactive surface is four things: `tap`, `select`, `group` and
/// `input`. v2 needed thirty-three node types to express less.

public struct SelectBehavior: Equatable, Sendable {
    public var group: String
    public var value: String
    /// The label to record as the answer's title, for analytics and for
    /// interpolation elsewhere on the flow.
    public var title: String?

    public init(group: String, value: String, title: String? = nil) {
        self.group = group
        self.value = value
        self.title = title
    }
}

public struct GroupBehavior: Equatable, Sendable {
    public var name: String
    /// Move on as soon as an option is chosen.
    public var autoAdvance: Bool
    /// More than one value may be held at once, encoded as a JSON array.
    public var multi: Bool
    /// Where the answer is stored, if the group names somewhere other than
    /// itself.
    public var saveTo: String?

    public init(name: String, autoAdvance: Bool = false, multi: Bool = false, saveTo: String? = nil) {
        self.name = name
        self.autoAdvance = autoAdvance
        self.multi = multi
        self.saveTo = saveTo
    }
}

public struct InputBehavior: Equatable, Sendable {
    public var saveTo: String
    /// `text`, `number`, `email`, `toggle`, `slider` — what keyboard to raise
    /// and which native control to overlay.
    public var kind: String
    public var placeholder: String?
    public var secure: Bool

    public init(saveTo: String, kind: String, placeholder: String? = nil, secure: Bool = false) {
        self.saveTo = saveTo
        self.kind = kind
        self.placeholder = placeholder
        self.secure = secure
    }
}

/// One node's interactive behaviour.
public struct TapTarget: Equatable, Sendable {
    public var path: String
    public var select: SelectBehavior?
    public var actions: [String]
    public var input: InputBehavior?

    public init(
        path: String, select: SelectBehavior? = nil,
        actions: [String] = [], input: InputBehavior? = nil
    ) {
        self.path = path
        self.select = select
        self.actions = actions
        self.input = input
    }

    public var isInteractive: Bool { select != nil || !actions.isEmpty || input != nil }
}

public struct InteractionMap: Equatable, Sendable {
    public var targets: [String: TapTarget]
    /// Group configuration by name, so a `select` naming a group can find out
    /// whether the group auto-advances or holds several values.
    public var groups: [String: GroupBehavior]

    public init(targets: [String: TapTarget] = [:], groups: [String: GroupBehavior] = [:]) {
        self.targets = targets
        self.groups = groups
    }

    /// The node that actually handles a touch on `path`.
    ///
    /// Walks UP from the hit. A tap lands on whatever is topmost — usually a
    /// text node or an emoji — and the thing that reacts is the card around it,
    /// which is what DOM bubbling gives the web for free and what a flat hit
    /// test has to do deliberately. Without this, tapping the word "Weekly"
    /// selects nothing while tapping the millimetre beside it works.
    public func handler(for path: String) -> TapTarget? {
        var current: Substring = path[...]
        while true {
            if let hit = targets[String(current)], hit.isInteractive { return hit }
            guard let dot = current.lastIndex(of: ".") else {
                // The root is "" — one last look before giving up.
                if current.isEmpty { return nil }
                current = ""
                continue
            }
            current = current[current.startIndex..<dot]
        }
    }

    /// The answers after choosing `value` in a group — the group's own rules
    /// applied, rather than a plain assignment.
    ///
    /// A multi group toggles within a JSON array, which is the encoding the
    /// rest of the platform reads; a single group replaces. Returning the new
    /// answers instead of mutating keeps this testable and keeps the view's
    /// state ownership in the view.
    public func answers(
        applying select: SelectBehavior, to answers: [String: String]
    ) -> [String: String] {
        let group = groups[select.group]
        let key = group?.saveTo ?? select.group
        var out = answers
        guard group?.multi == true else {
            out[key] = select.value
            return out
        }
        var held = decodeList(answers[key])
        if let at = held.firstIndex(of: select.value) {
            held.remove(at: at)
        } else {
            held.append(select.value)
        }
        out[key] = encodeList(held)
        return out
    }

    public func autoAdvances(_ select: SelectBehavior) -> Bool {
        groups[select.group]?.autoAdvance == true
    }
}

/// `["a","b"]` — the canonical multi-select encoding — or a bare scalar.
public func decodeList(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    guard raw.hasPrefix("[") else { return [raw] }
    // Hand-parsed rather than via JSONSerialization, because this file is in
    // the platform-free target and the format is one level of strings.
    let inner = raw.dropFirst().dropLast()
    return inner.split(separator: ",").compactMap {
        let t = $0.trimmingCharactersInSet(" \"")
        return t.isEmpty ? nil : t
    }
}

public func encodeList(_ values: [String]) -> String {
    guard !values.isEmpty else { return "[]" }
    return "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
}

private extension Substring {
    func trimmingCharactersInSet(_ set: String) -> String {
        var s = self
        while let f = s.first, set.contains(f) { s = s.dropFirst() }
        while let l = s.last, set.contains(l) { s = s.dropLast() }
        return String(s)
    }
}
