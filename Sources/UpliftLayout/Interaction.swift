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
    ///
    /// The document spells this `behavior.group.mode: "multi"`; see
    /// `LayoutDecoder.interactions`, which is the only place it is decoded.
    public var multi: Bool
    /// Where the answer is stored, if the group names somewhere other than
    /// itself.
    public var saveTo: String?
    /// How many values a `multi` group must and may hold. `max` is enforced
    /// here — a tap that would exceed it is refused rather than silently
    /// dropping the oldest answer. `min` is a gate on leaving the screen, which
    /// this type only carries; nothing in the renderer acts on it yet.
    public var min: Int?
    public var max: Int?

    public init(
        name: String, autoAdvance: Bool = false, multi: Bool = false,
        saveTo: String? = nil, min: Int? = nil, max: Int? = nil
    ) {
        self.name = name
        self.autoAdvance = autoAdvance
        self.multi = multi
        self.saveTo = saveTo
        self.min = min
        self.max = max
    }
}

public struct InputBehavior: Equatable, Sendable {
    public var saveTo: String
    /// `text`, `number`, `email`, `toggle`, `slider` — what keyboard to raise
    /// and which native control to overlay.
    public var kind: String
    public var placeholder: String?
    public var secure: Bool
    /// A slider's range and granularity, and a date field's presentation —
    /// props the control cannot be built without.
    public var min: Double?
    public var max: Double?
    public var step: Double?
    /// `field` | `big` | `wheel` | `calendar`.
    public var variant: String?

    public init(
        saveTo: String, kind: String, placeholder: String? = nil, secure: Bool = false,
        min: Double? = nil, max: Double? = nil, step: Double? = nil, variant: String? = nil
    ) {
        self.saveTo = saveTo
        self.kind = kind
        self.placeholder = placeholder
        self.secure = secure
        self.min = min
        self.max = max
        self.step = step
        self.variant = variant
    }
}

/// A photo frame, and what the host's picker is allowed to offer.
///
/// The SDK ships no camera or gallery dependency — an app that collects photos
/// already has a picker and already owns the OS prompts that come with it. So
/// this is the handoff: what the author permitted, and where the answer goes.
public struct PhotoUploadBehavior: Equatable, Sendable {
    public var saveTo: String
    /// `camera` | `library` | `both`.
    public var source: String
    /// `square` | `circle` — the crop the screen was drawn for.
    public var shape: String

    public init(saveTo: String, source: String = "both", shape: String = "square") {
        self.saveTo = saveTo
        self.source = source
        self.shape = shape
    }
}

/// The sealed sign-in stack: the buttons are Apple's and Google's.
public struct SignInBehavior: Equatable, Sendable {
    public var saveTo: String
    /// Provider ids in the order the author listed them.
    public var providers: [String]
    /// Labels the author overrode, by provider id.
    public var labels: [String: String]
    /// `auto` | `light` | `dark`.
    public var appearance: String
    public var advanceOnSuccess: Bool

    public init(
        saveTo: String, providers: [String], labels: [String: String] = [:],
        appearance: String = "auto", advanceOnSuccess: Bool = true
    ) {
        self.saveTo = saveTo
        self.providers = providers
        self.labels = labels
        self.appearance = appearance
        self.advanceOnSuccess = advanceOnSuccess
    }
}

/// The sealed permission node — the dialog is the system's.
public struct PermissionBehavior: Equatable, Sendable {
    public var saveTo: String
    /// `camera` | `photos` | `notifications` | … — the nine the schema names.
    public var permission: String
    public var advanceOnResult: Bool

    public init(saveTo: String, permission: String, advanceOnResult: Bool = true) {
        self.saveTo = saveTo
        self.permission = permission
        self.advanceOnResult = advanceOnResult
    }
}

/// One node's interactive behaviour.
public struct TapTarget: Equatable, Sendable {
    public var path: String
    public var select: SelectBehavior?
    public var actions: [String]
    public var input: InputBehavior?
    /// The three sealed leaves. They carry no `behavior.tap` — the node type
    /// IS the behaviour — so without them a tap on a photo frame, a sign-in
    /// stack or a permission row reaches nothing at all, which is what the
    /// device did: the boxes were drawn and none of them answered.
    public var photoUpload: PhotoUploadBehavior?
    public var signIn: SignInBehavior?
    public var permission: PermissionBehavior?

    public init(
        path: String, select: SelectBehavior? = nil,
        actions: [String] = [], input: InputBehavior? = nil,
        photoUpload: PhotoUploadBehavior? = nil,
        signIn: SignInBehavior? = nil,
        permission: PermissionBehavior? = nil
    ) {
        self.path = path
        self.select = select
        self.actions = actions
        self.input = input
        self.photoUpload = photoUpload
        self.signIn = signIn
        self.permission = permission
    }

    public var isInteractive: Bool {
        select != nil || !actions.isEmpty || input != nil
            || photoUpload != nil || signIn != nil || permission != nil
    }
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
            // A group past its `max` refuses the tap rather than evicting an
            // earlier answer: the user chose those, and silently dropping one
            // to make room reads as the screen losing an answer at random.
            if let max = group?.max, held.count >= max { return answers }
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
