import Foundation

/// Turning a served document into something the solver can lay out.
///
/// Two jobs, and they happen here rather than in the solver on purpose. The
/// solver should be arithmetic over a settled tree, so everything that decides
/// WHICH tree that is — which state each node is in, which nodes exist at all —
/// is resolved first. That mirrors the web renderer, where `resolveNode` runs
/// before any CSS is emitted and a node whose condition fails returns `null`
/// rather than rendering transparent.

/// The answers a screen is being laid out against.
///
/// A selection changes which state a card is in, which changes its delta, which
/// changes its frame — so parity against a baseline dumped with `sel=plan:monthly`
/// requires laying out with the same answers.
public struct LayoutInput: Sendable {
    public var selections: [String: String]
    public var variables: [String: String]
    /// Store data per product ref, for the `{{product.*}}` tokens.
    ///
    /// A product-bound box publishes these into its own subtree, which is what
    /// lets a plan card be composed rather than configured. The price is not in
    /// the document — it comes from the store — so laying out without it
    /// measures the literal `{{product.price}}`, seventeen unbreakable
    /// characters that size the row completely differently from "€8.99".
    public var products: [String: [String: String]]

    /// key → copy, for the locale being laid out.
    ///
    /// Text is measured, so the SHAPED STRING has to be the one the user sees.
    /// Laying out `{ key: "paywall.title" }` would measure the key — a silent
    /// wrong answer, since a key is a plausible-looking string of about the
    /// right length.
    public var catalog: [String: String]

    /// The flow's colour tokens — `primary`, `surface`, `border` and the rest.
    ///
    /// A node names a token far more often than a hex value, so without these
    /// every card in the corpus decodes to no fill at all. Pulled from the
    /// document by `layoutTree(flow:)` for the same reason the catalog is: the
    /// caller should not have to know where the theme lives.
    public var tokens: [String: String]

    /// The clock, as an INPUT rather than a call to `Date()`.
    ///
    /// `behavior.countdown` publishes a time that changes every second into
    /// text that gets measured, so the decoder would stop being a pure function
    /// of its arguments the moment it read the clock itself — and the golden
    /// route could never record a stable frame. Epoch milliseconds; zero means
    /// the caller has no clock to give.
    public var now: Double
    /// When the screen being laid out appeared — what `duration_ms` counts from.
    public var screenEnteredAt: Double

    public init(
        selections: [String: String] = [:],
        variables: [String: String] = [:],
        catalog: [String: String] = [:],
        products: [String: [String: String]] = [:],
        tokens: [String: String] = [:],
        now: Double = 0,
        screenEnteredAt: Double = 0
    ) {
        self.selections = selections
        self.variables = variables
        self.catalog = catalog
        self.products = products
        self.tokens = tokens
        self.now = now
        self.screenEnteredAt = screenEnteredAt
    }
}

/// Named `LayoutDecoder` rather than `Decoder`, which is what it was until the
/// Flutter plugin vendored both targets into ONE CocoaPods module and the
/// shadowing became a compile error: `Decoder` is a Swift standard-library
/// protocol, and `JSONValue`'s `init(from decoder: Decoder)` resolved to this
/// enum instead of to it.
///
/// SPM hid it, because the two lived in separate modules. It was a hazard the
/// whole time — a public type shadowing a standard protocol traps anyone
/// writing `Codable` conformance nearby — and the merge only made it impossible
/// to ignore.
public enum LayoutDecoder {
    /// Decode one screen's root into a laid-out-able tree.
    public static func layoutTree(
        screen: [String: Any],
        input: LayoutInput = LayoutInput()
    ) -> LayoutNode? {
        guard let root = screen["root"] as? [String: Any] else { return nil }
        return node(root, path: "", input: input, inheritedState: nil)
    }

    /// Which step of its progress sequence a screen is — the input that decides
    /// completed/current/upcoming for every node carrying `behavior.step`.
    ///
    /// A progress bar is a row of boxes that each declare their own index, so
    /// the tree says what the sequence looks like and nothing in it says where
    /// the user currently is. That is a property of the FLOW: the screens
    /// drawing the same sequence, in document order, are its steps, and this
    /// screen's position among them is the answer.
    ///
    /// The decoder reads it as `variables["__stepIndex"]`, which nothing was
    /// writing — so every screen laid out as step zero and the bar never moved.
    /// Mirrors `stepIndexOf` in @funnel/schema. Nil when the screen draws no
    /// sequence, which is most of them.
    public static func stepIndex(flow: [String: Any], screenIndex: Int) -> Int? {
        guard let screens = flow["screens"] as? [[String: Any]],
              screens.indices.contains(screenIndex) else { return nil }
        guard let sequence = sequences(in: screens[screenIndex]).first else { return nil }
        var position = 0
        for (i, screen) in screens.enumerated() {
            guard sequences(in: screen).contains(sequence) else { continue }
            if i == screenIndex { return position }
            position += 1
        }
        return nil
    }

    /// The `behavior.step` sequence names a screen's tree draws, first seen first.
    private static func sequences(in screen: [String: Any]) -> [String] {
        var out: [String] = []
        func walk(_ any: Any?) {
            if let list = any as? [Any] {
                list.forEach(walk)
                return
            }
            guard let node = any as? [String: Any] else { return }
            if let step = (node["behavior"] as? [String: Any])?["step"] as? [String: Any] {
                let name = (step["of"] as? String) ?? ""
                if !out.contains(name) { out.append(name) }
            }
            for value in node.values { walk(value) }
        }
        walk(screen["root"])
        return out
    }

    /// Decode a whole flow's screen, pulling the catalog out of the document so
    /// the caller does not have to know how localization is stored.
    public static func layoutTree(
        flow: [String: Any],
        screenIndex: Int,
        locale: String? = nil,
        input: LayoutInput = LayoutInput()
    ) -> LayoutNode? {
        guard let screens = flow["screens"] as? [[String: Any]],
              screens.indices.contains(screenIndex) else { return nil }
        let loc = locale ?? (flow["default_locale"] as? String) ?? "en"
        let all = flow["localizations"] as? [String: [String: String]] ?? [:]
        var merged = input
        merged.catalog = all[loc] ?? all[(flow["default_locale"] as? String) ?? "en"] ?? [:]
        if merged.tokens.isEmpty {
            let theme = flow["theme"] as? [String: Any]
            let tokens = theme?["tokens"] as? [String: Any]
            merged.tokens = (tokens?["colors"] as? [String: String]) ?? [:]
        }
        return layoutTree(screen: screens[screenIndex], input: merged)
    }

    // MARK: - one node

    private static func node(
        _ raw: [String: Any],
        path: String,
        input: LayoutInput,
        inheritedState: String?
    ) -> LayoutNode? {
        let type = raw["type"] as? String ?? "box"
        let behavior = raw["behavior"] as? [String: Any]

        // Which state this node renders in, and what it passes down. A node
        // that establishes one gives it to its whole subtree — that is how a
        // radio dot inside a plan card knows the card is selected.
        let own = ownState(behavior, raw: raw, input: input)
        let active = own ?? inheritedState
        let delta = active.flatMap { (raw["states"] as? [String: Any])?[$0] as? [String: Any] }

        // Merged one level deep, exactly as `render/state.ts` merges: an absent
        // key in the delta keeps the base value.
        let selfG = merge(raw["self"] as? [String: Any], delta?["self"] as? [String: Any])
        let layoutG = merge(raw["layout"] as? [String: Any], delta?["layout"] as? [String: Any])
        let visible = delta?["visible"] ?? raw["visible"]

        // Invisible means ABSENT, not transparent: it takes no space, which is
        // what the device does and what the frame baseline recorded.
        if let v = visible as? Bool, v == false { return nil }
        if let cond = visible as? [String: Any], !conditionHolds(cond["when"], input: input) { return nil }

        // A product-bound box scopes `{{product.*}}` for everything beneath it.
        var input = input
        if let ref = (behavior?["product"] as? [String: Any])?["ref"] as? String {
            let info = input.products[ref] ?? [:]
            for key in ["price", "period", "trial", "original_price", "savings"] {
                input.variables["product.\(key)"] = info[key] ?? ""
            }
        }

        // A countdown box scopes `{{countdown.*}}` the same way. Same mechanism
        // as `product` on purpose: the schema says the units are drawn by an
        // ordinary preset tree, so they have to arrive as ordinary text.
        if let spec = behavior?["countdown"] as? [String: Any] {
            for (key, value) in countdownVars(spec, input: input) {
                input.variables[key] = value
            }
        }

        var n = LayoutNode(path: path, type: type)

        if let s = selfG {
            n.position = (s["position"] as? String).flatMap(Position.init(rawValue:)) ?? .relative
            n.width = size(s["width"])
            n.height = size(s["height"])
            n.grow = (s["grow"] as? NSNumber)?.doubleValue
            n.z = (s["z"] as? NSNumber)?.intValue
            n.ignoreSafeArea = (s["ignoreSafeArea"] as? Bool) ?? false
            n.minWidth = dbl(s["minWidth"])
            n.maxWidth = dbl(s["maxWidth"])
            n.minHeight = dbl(s["minHeight"])
            n.maxHeight = dbl(s["maxHeight"])
            n.aspect = dbl(s["aspect"])
            n.margin = edges(s["margin"])
            n.anchorX = (s["anchorX"] as? String).flatMap(Align.init(rawValue:))
            n.anchorY = (s["anchorY"] as? String).flatMap(Align.init(rawValue:))
            if let i = s["inset"] as? [String: Any] {
                n.inset = Edges(
                    top: dbl(i["top"]) ?? 0, right: dbl(i["right"]) ?? 0,
                    bottom: dbl(i["bottom"]) ?? 0, left: dbl(i["left"]) ?? 0
                )
                n.insetSides = (
                    top: i["top"] != nil, right: i["right"] != nil,
                    bottom: i["bottom"] != nil, left: i["left"] != nil
                )
            }
        }

        if let l = layoutG {
            n.mode = (l["mode"] as? String).flatMap(LayoutMode.init(rawValue:)) ?? .column
            n.padding = edges(l["padding"])
            n.alignX = (l["alignX"] as? String).flatMap(Align.init(rawValue:))
            n.alignY = (l["alignY"] as? String).flatMap(Align.init(rawValue:))
            n.distribute = (l["distribute"] as? String)
                .flatMap(Distribute.init(rawValue:)) ?? .packed
            if let g = dbl(l["gap"]) {
                n.gapMain = g
            } else if let g = l["gap"] as? [String: Any] {
                n.gapMain = dbl(g["main"]) ?? 0
            }
        }

        let styleG = merge(raw["style"] as? [String: Any], delta?["style"] as? [String: Any])
        if let stroke = styleG?["stroke"] as? [String: Any] {
            // Layout only cares that an INSIDE stroke eats the content box. An
            // outside one is painted past the bounds and moves nothing, so it
            // must not narrow the children.
            let inside = (stroke["align"] as? String ?? "inside") == "inside"
            n.borderWidth = inside ? (dbl(stroke["width"]) ?? 1) : 0
        }
        n.paint = paintStyle(styleG, tokens: input.tokens)
        // Three separate facts, where this used to be one. `clip ?? (scroll !=
        // nil)` lost the axis, and a scroller with no axis is just a box that
        // hides everything past its edge.
        n.clipsContent = (layoutG?["clip"] as? Bool) ?? false
        if let axis = layoutG?["scroll"] as? String, axis != "none" {
            n.scroll = ScrollAxis(rawValue: axis)
        }
        n.snap = (layoutG?["snap"] as? String).flatMap(SnapAlign.init(rawValue:))
        // `peek` is LAYOUT, not decoration: the web writes it as padding on the
        // scroller itself (`overflowCss`), so it changes the content box the
        // children divide up. Trailing edge only, and horizontal only — it is
        // the sliver of the next card you leave showing.
        if let peek = dbl(layoutG?["peek"]), n.scroll == .horizontal {
            n.padding.right += peek + n.gapMain
        }
        n.text = textRun(raw, type: type, style: styleG, input: input)

        let props = raw["props"] as? [String: Any]
        if n.text != nil {
            let t = styleG?["text"] as? [String: Any]
            n.textColor = RGBA.parse(t?["color"] as? String, tokens: input.tokens)
                // The renderer falls back to the palette's primary text colour
                // rather than to black, and on a dark theme those differ.
                ?? RGBA.parse("text_primary", tokens: input.tokens)
            n.textAlign = (props?["align"] as? String).flatMap(TextAlign.init(rawValue:)) ?? .start
            n.maxLines = (props?["maxLines"] as? NSNumber)?.intValue
        }
        if type == "image" {
            let p = (props?["position"] as? [NSNumber])?.map(\.doubleValue) ?? [0.5, 0.5]
            n.image = (
                url: interpolate(localized(props?["url"], input), input: input),
                fit: (props?["fit"] as? String).flatMap(ImageFit.init(rawValue:)) ?? .cover,
                position: Point2D(x: p.first ?? 0.5, y: p.count > 1 ? p[1] : 0.5)
            )
        }

        // The height a native leaf occupies, when the platform decides it rather
        // than content does.
        //
        // Only `input` had one, which meant every other sealed leaf decoded as
        // a zero-height box: a sign-in stack, a permission explainer and a
        // photo frame all solved to nothing and the renderer drew them over
        // whatever came next. Mirrors `applyControlSize` in decode.ts — these
        // numbers are the cross-platform contract, not a web detail.
        switch type {
        case "signin":
            // A column of provider buttons: 14pt padding around a 16pt label,
            // 10pt apart. Apple and Google own these, so their size is not ours.
            let providers = (props?["providers"] as? [[String: Any]])?.count ?? 0
            let count = min(max(providers, 1), 5)
            let button = 2 * 14 + lu(16 * 1.2)
            n.controlHeight = Double(count) * button + Double(count - 1) * 10
        case "permission":
            // The dialog is the system's; what occupies the tree is the row
            // standing in for it.
            n.controlHeight = 2 * 12 + lu(13 * 1.2) + 2
        case "photo_upload":
            // A circular frame is a fixed 140pt disc plus its 2pt ring; a
            // rectangular one is width-driven at 3:2, and has to claim the
            // width too — an aspect on a HUG box with no content resolves
            // against zero and comes out zero tall.
            if (props?["shape"] as? String) == "circle" {
                n.controlHeight = 144
                if n.width == .hug { n.width = .points(144) }
            } else {
                if n.width == .hug { n.width = .fill }
                if n.aspect == nil { n.aspect = 1.5 }
            }
        case "paywall_handoff", "custom":
            n.controlHeight = 2 * 10 + lu(12 * 1.2) + 2
        default:
            break
        }

        // `controlBox` in the web renderer: 12pt of vertical padding around a
        // single 16pt body line — three lines for a multiline, which is what
        // `rows={3}` draws. A switch and a slider are fixed-size controls.
        if type == "input" {
            let kind = (behavior?["input"] as? [String: Any])?["kind"] as? String ?? "text"
            if kind == "toggle" {
                n.controlHeight = 32
            } else if kind == "slider" {
                n.controlHeight = 24
            } else {
                let body = TYPE_RAMP["body"]!
                let lines: Double = (props?["multiline"] as? Bool) == true ? 3 : 1
                n.controlHeight = 2 * 12 + lu(body.size * body.lineHeight) * lines
                // `controlBox` on the web: 12pt vertical, 14pt horizontal.
                n.padding = Edges(top: 12, right: 14, bottom: 12, left: 14)

                // The answer if there is one, the placeholder if not — which is
                // what a text field shows and what the two `name-input` shots
                // differ by.
                let answer = (raw["bind"] as? [String: Any])?["save_to"] as? String
                let value = answer.flatMap { input.variables[$0] } ?? ""
                let showing = value.isEmpty
                    ? interpolate(localized(props?["placeholder"], input), input: input)
                    : value
                if !showing.isEmpty {
                    n.controlText = TextRunSpec(
                        text: showing,
                        fontSize: body.size,
                        fontWeight: WEIGHTS[body.weight] ?? 400,
                        lineHeight: body.lineHeight
                    )
                    n.textColor = RGBA.parse(
                        value.isEmpty ? "text_secondary" : "text_primary", tokens: input.tokens
                    )
                }
            }
        }

        let passDown = own ?? inheritedState
        var kids: [LayoutNode] = []
        for (i, childRaw) in ((raw["children"] as? [[String: Any]]) ?? []).enumerated() {
            let childPath = path.isEmpty ? "\(i)" : "\(path).\(i)"
            if let c = node(childRaw, path: childPath, input: input, inheritedState: passDown) {
                kids.append(c)
            }
        }
        n.children = kids
        return n
    }

    // MARK: - state

    /// Mirrors `ownState` in `render/state.ts`, including its precedence: a
    /// step's position in a sequence is structural and nothing overrides it.
    private static func ownState(
        _ behavior: [String: Any]?, raw: [String: Any], input: LayoutInput
    ) -> String? {
        guard let b = behavior else { return nil }
        if let step = b["step"] as? [String: Any], let idx = (step["index"] as? NSNumber)?.intValue {
            let current = Int(input.variables["__stepIndex"] ?? "0") ?? 0
            if idx < current { return "completed" }
            if idx == current { return "current" }
            return "upcoming"
        }
        // Between `step` and `select`, exactly as `render/state.ts` orders them:
        // a failing field reddens even inside a selected card.
        if isInvalid(raw, input: input) { return "invalid" }
        if let select = b["select"] as? [String: Any],
           let group = select["group"] as? String,
           let value = select["value"] as? String {
            guard let chosen = input.selections[group] else {
                // Nothing answered yet, so the author's default is what shows.
                return (select["default"] as? Bool) == true ? "selected" : nil
            }
            return chosen == value ? "selected" : nil
        }
        return nil
    }

    /// Whether a node's field has been answered AND fails its own rules.
    ///
    /// Answered first, and it is the whole difference between the two
    /// `name-input` shots: an untouched empty field is not invalid, a touched
    /// and emptied one is. `selections` records the touch — a key present with
    /// an empty value — which is why absence and emptiness cannot be collapsed.
    private static func isInvalid(_ raw: [String: Any], input: LayoutInput) -> Bool {
        guard (raw["behavior"] as? [String: Any])?["input"] != nil,
              let field = governedField(raw) else { return false }
        guard let value = input.selections[field.saveTo] else { return false }
        return field.rules.contains { !ruleHolds($0, value: value) }
    }

    /// The rules a node answers for — its own, or its first descendant's.
    ///
    /// A box carrying `behavior.input` claims the field beneath it, which is
    /// how the pill AROUND the text field reddens: the input has no edge of its
    /// own, so the container has to know the field failed.
    private static func governedField(
        _ raw: [String: Any]
    ) -> (rules: [[String: Any]], saveTo: String)? {
        let rules = ((raw["behavior"] as? [String: Any])?["input"] as? [String: Any])?["validate"]
        if let rules = rules as? [[String: Any]], !rules.isEmpty,
           let saveTo = (raw["bind"] as? [String: Any])?["save_to"] as? String {
            return (rules, saveTo)
        }
        for child in (raw["children"] as? [[String: Any]]) ?? [] {
            if let hit = governedField(child) { return hit }
        }
        return nil
    }

    private static func ruleHolds(_ rule: [String: Any], value: String) -> Bool {
        let threshold = rule["value"]
        switch rule["rule"] as? String {
        case "required":
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "min_length":
            return value.count >= (Int("\(threshold ?? 0)") ?? 0)
        case "max_length":
            return value.count <= (Int("\(threshold ?? "")") ?? .max)
        case "min":
            // A non-numeric value is not "too small" — that is a different
            // failure and `min` is not the rule that should report it.
            guard let n = Double(value) else { return true }
            return n >= (dbl(threshold) ?? -.greatestFiniteMagnitude)
        case "max":
            guard let n = Double(value) else { return true }
            return n <= (dbl(threshold) ?? .greatestFiniteMagnitude)
        case "has_uppercase": return value.contains { $0.isUppercase }
        case "has_lowercase": return value.contains { $0.isLowercase }
        case "has_digit": return value.contains { $0.isNumber }
        default:
            // An unknown rule cannot be checked, and failing a field over a rule
            // this build does not understand would break older documents.
            // `pattern` lands here on purpose: NSRegularExpression and
            // JavaScript's engine disagree about enough syntax that running the
            // author's regex through a different one would redden fields the
            // browser passes.
            return true
        }
    }

    /// Mirrors `evaluateCondition`, for the operators the corpus uses.
    private static func conditionHolds(_ raw: Any?, input: LayoutInput) -> Bool {
        guard let c = raw as? [String: Any], let variable = c["var"] as? String else { return true }
        let op = c["op"] as? String ?? "is_set"
        let actual = input.selections[variable] ?? input.variables[variable]
        let expected = c["value"].map { "\($0)" }
        switch op {
        case "is_set": return actual != nil && actual != "" && actual != "[]"
        case "not_set": return actual == nil || actual == "" || actual == "[]"
        case "==": return actual == expected
        case "!=": return actual != expected
        case "contains": return actual?.contains(expected ?? "") ?? false
        default: return true
        }
    }

    // MARK: - leaves

    private static func textRun(
        _ raw: [String: Any],
        type: String,
        style: [String: Any]?,
        input: LayoutInput
    ) -> TextRunSpec? {
        guard type == "text" || type == "icon" else { return nil }
        let props = raw["props"] as? [String: Any]

        // An icon is NOT a styled text node. The renderer builds it from `props`
        // alone — size, glyph, colour — and pins `line-height: 1`; it never
        // looks at `style.text`, so a role, a weight or a line height set on one
        // does nothing on the web and must do nothing here.
        //
        // Reading the ramp instead put every emoji's box at 1.45 line heights:
        // an 18pt icon came out 26.09 tall against Chromium's 18, and the extra
        // eight points pushed every sibling below it down the screen.
        if type == "icon" {
            let glyph = (props?["emoji"] as? String) ?? (props?["glyph"] as? String) ?? "•"
            guard !glyph.isEmpty else { return nil }
            return TextRunSpec(
                text: glyph,
                fontSize: dbl(props?["size"]) ?? 24,
                fontWeight: 400,
                letterSpacing: 0,
                lineHeight: 1
            )
        }

        let plain = plainText(props, input: input)
        guard !plain.isEmpty else { return nil }
        let t = style?["text"] as? [String: Any]
        // Case is applied BEFORE measuring, because it changes the width. An
        // uppercased label measures narrower than it paints, which is what
        // wrapped "BEST VALUE" inside a badge sized for "Best value".
        let text: String
        switch t?["transform"] as? String {
        case "uppercase": text = plain.uppercased()
        case "lowercase": text = plain.lowercased()
        default: text = plain
        }
        let role = t?["role"] as? String ?? "body"
        let ramp = TYPE_RAMP[role] ?? TYPE_RAMP["body"]!
        let size = dbl(t?["size"]) ?? ramp.size
        let weight = WEIGHTS[t?["weight"] as? String ?? ramp.weight] ?? 400
        let tracking = dbl(t?["letterSpacing"]) ?? 0
        let multiplier = dbl(t?["lineHeight"]) ?? ramp.lineHeight

        return TextRunSpec(
            text: text,
            fontSize: size,
            fontWeight: weight,
            letterSpacing: tracking,
            lineHeight: multiplier,
            spans: spans(
                props,
                input: input,
                size: size, weight: weight, tracking: tracking, role: role
            )
        )
    }

    /// `props.spans` as inline segments, each inheriting what it does not name.
    ///
    /// The renderer is explicit about the inheritance — it builds each span's
    /// CSS from the span's own style and then DELETES `fontSize`, `lineHeight`
    /// and `fontWeight` again unless the span set them, so an unstyled span is
    /// indistinguishable from the node's own text. Anything else here would
    /// silently restyle every span that only meant to change colour.
    private static func spans(
        _ props: [String: Any]?,
        input: LayoutInput,
        size: Double,
        weight: Int,
        tracking: Double,
        role: String
    ) -> [TextSegment]? {
        guard let raw = props?["spans"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let ramp = TYPE_RAMP[role] ?? TYPE_RAMP["body"]!
        return raw.map { span in
            let s = span["style"] as? [String: Any]
            return TextSegment(
                text: interpolate(localized(span["text"], input), input: input),
                fontSize: dbl(s?["size"]) ?? size,
                // A span naming a weight resolves it; one that does not keeps
                // the node's. The renderer falls back to the RAMP's weight for a
                // span whose style exists but names no weight, which is the same
                // value whenever the node did not override it either.
                fontWeight: (s?["weight"] as? String).flatMap { WEIGHTS[$0] }
                    ?? (s == nil ? weight : (WEIGHTS[ramp.weight] ?? weight)),
                letterSpacing: dbl(s?["letterSpacing"]) ?? tracking,
                lineHeight: dbl(s?["lineHeight"]),
                color: RGBA.parse(s?["color"] as? String, tokens: input.tokens)
            )
        }
    }

    /// A text node's value, or its spans joined — the shaper sees one run
    /// either way, which is what the browser lays out.
    private static func plainText(_ props: [String: Any]?, input: LayoutInput) -> String {
        guard let p = props else { return "" }
        if let spans = p["spans"] as? [[String: Any]] {
            return spans.map { interpolate(localized($0["text"], input), input: input) }.joined()
        }
        return interpolate(localized(p["value"], input), input: input)
    }

    /// The corpus is laid out against resolved copy, which the baseline
    /// recorded; a `{ key }` that reached here would be a missing catalog
    /// entry, and measuring the key text would be a silent wrong answer.
    static func localized(_ v: Any?, _ input: LayoutInput) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any], let k = d["key"] as? String {
            // A key with no entry is left visible rather than blanked: an empty
            // string measures as nothing and the layout silently closes up,
            // where a visible key shows exactly which entry is missing.
            return input.catalog[k] ?? k
        }
        return ""
    }

    /// `{{token}}` substitution, matching `render/context.ts`.
    ///
    /// An unresolved token — or one whose value is EMPTY — renders as the
    /// literal `{{name}}` rather than as nothing. Text is measured, so a token
    /// that collapses to "" changes the width of the line it is on: the focus
    /// screen's headline is recorded by the browser with its braces still in
    /// place, and a renderer that dropped them lays out a shorter sentence than
    /// the one on screen.
    ///
    /// The empty case was wrong here until the TypeScript port was checked
    /// against the same recording. It had been substituting an empty value,
    /// which the corpus never exercises — `first_name` is either absent or set.
    static func interpolate(_ s: String, input: LayoutInput) -> String {
        guard s.contains("{{") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "{{") {
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                break
            }
            let name = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let value = input.variables[name] ?? input.selections[name]
            out += rest[rest.startIndex..<open.lowerBound]
            if let value, !value.isEmpty {
                out += displayValue(value)
            } else {
                out += "{{\(name)}}"
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// A multi-select writes its variable JSON-encoded (`["a","b"]`). Copy that
    /// interpolates one must read as a list, not leak the array literal.
    private static func displayValue(_ v: String) -> String {
        guard v.hasPrefix("["), let data = v.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return v }
        return list.map { "\($0)" }.joined(separator: ", ")
    }

    /// `{{countdown.days}}` and friends, for one `behavior.countdown`.
    ///
    /// Zero-padded to two digits, because a paywall's timer is read as a clock
    /// and an unpadded "9" beside "58" jumps a whole character width every ten
    /// seconds — which, since the text is measured, moves the layout with it.
    /// Days are not padded: a count, not a clock field.
    static func countdownVars(_ spec: [String: Any], input: LayoutInput) -> [String: String] {
        let deadline: Double
        if let target = spec["target"] as? String, let at = iso8601(target) {
            deadline = at
        } else {
            deadline = input.screenEnteredAt + ((spec["duration_ms"] as? NSNumber)?.doubleValue ?? 0)
        }
        // A zero clock means the caller has no time to give (the golden route),
        // so the countdown shows its full length rather than a deadline long past.
        let left = max(0, input.now == 0 ? deadline - input.screenEnteredAt : deadline - input.now)
        let total = Int(left / 1000)
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return [
            "countdown.days": "\(total / 86400)",
            "countdown.hours": pad(total / 3600 % 24),
            "countdown.minutes": pad(total / 60 % 60),
            "countdown.seconds": pad(total % 60),
        ]
    }

    /// Epoch milliseconds for an ISO-8601 instant, or nil.
    ///
    /// Two formatters because `.withFractionalSeconds` REJECTS a string without
    /// them rather than tolerating it, and the schema's example
    /// (`2026-01-01T00:00:00Z`) has none.
    private static func iso8601(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: - primitives

    private static func merge(_ base: [String: Any]?, _ delta: [String: Any]?) -> [String: Any]? {
        guard let d = delta else { return base }
        guard var b = base else { return d }
        for (k, v) in d { b[k] = v }
        return b
    }

    static func dbl(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func size(_ v: Any?) -> Size {
        if let s = v as? String {
            if s == "fill" { return .fill }
            if s == "hug" { return .hug }
            if s.hasSuffix("%"), let n = Double(s.dropLast()) { return .percent(n) }
        }
        if let n = dbl(v) { return .points(n) }
        return .hug
    }

    /// `[t, r, b, l]`, one number for all four, or an object.
    private static func edges(_ v: Any?) -> Edges {
        if let n = dbl(v) { return Edges(top: n, right: n, bottom: n, left: n) }
        if let a = v as? [NSNumber], a.count == 4 {
            return Edges(top: a[0].doubleValue, right: a[1].doubleValue,
                         bottom: a[2].doubleValue, left: a[3].doubleValue)
        }
        if let d = v as? [String: Any] {
            return Edges(top: dbl(d["top"]) ?? 0, right: dbl(d["right"]) ?? 0,
                         bottom: dbl(d["bottom"]) ?? 0, left: dbl(d["left"]) ?? 0)
        }
        return .zero
    }
}

/// The type ramp, normative per PRIMITIVE_SPEC §4 and mirrored by
/// `@funnel/layout`'s `ramp.ts`.
///
/// Four of these six were WRONG until the TypeScript port was written and the
/// two tables were finally read side by side: `title` was 28/1.2 against the
/// spec's 26/1.15, `subtitle` 20 against 19, `label` 15/1.3 against 14/1.2, and
/// `display` 1.15 against 1.1. The comment here claimed they were equal.
///
/// The acceptance corpus could not catch it. Every role-bearing node in both
/// fixtures also sets an explicit `size`, so these numbers were never once
/// consulted in a passing test — a document that leaned on a role would have
/// rendered two points different on iOS with the whole suite green. That is the
/// argument for the port in one paragraph: a second implementation reading the
/// same spec found what a shared test corpus structurally could not.
struct Ramp { let size: Double; let weight: String; let lineHeight: Double }

let TYPE_RAMP: [String: Ramp] = [
    "display": Ramp(size: 34, weight: "bold", lineHeight: 1.1),
    "title": Ramp(size: 26, weight: "bold", lineHeight: 1.15),
    "subtitle": Ramp(size: 19, weight: "medium", lineHeight: 1.3),
    "body": Ramp(size: 16, weight: "regular", lineHeight: 1.45),
    "caption": Ramp(size: 13, weight: "regular", lineHeight: 1.4),
    "label": Ramp(size: 14, weight: "medium", lineHeight: 1.2),
]

let WEIGHTS: [String: Int] = [
    "light": 300, "regular": 400, "medium": 500,
    "semibold": 600, "bold": 700, "black": 900,
]
