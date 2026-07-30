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

    public init(
        selections: [String: String] = [:],
        variables: [String: String] = [:],
        catalog: [String: String] = [:],
        products: [String: [String: String]] = [:]
    ) {
        self.selections = selections
        self.variables = variables
        self.catalog = catalog
        self.products = products
    }
}

public enum Decoder {
    /// Decode one screen's root into a laid-out-able tree.
    public static func layoutTree(
        screen: [String: Any],
        input: LayoutInput = LayoutInput()
    ) -> LayoutNode? {
        guard let root = screen["root"] as? [String: Any] else { return nil }
        return node(root, path: "", input: input, inheritedState: nil)
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
        let own = ownState(behavior, input: input)
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

        var n = LayoutNode(path: path, type: type)

        if let s = selfG {
            n.position = (s["position"] as? String).flatMap(Position.init(rawValue:)) ?? .relative
            n.width = size(s["width"])
            n.height = size(s["height"])
            n.grow = (s["grow"] as? NSNumber)?.doubleValue
            n.z = (s["z"] as? NSNumber)?.intValue
            n.ignoreSafeArea = (s["ignoreSafeArea"] as? Bool) ?? false
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
            if let g = dbl(l["gap"]) {
                n.gapMain = g
            } else if let g = l["gap"] as? [String: Any] {
                n.gapMain = dbl(g["main"]) ?? 0
            }
        }

        let styleG = merge(raw["style"] as? [String: Any], delta?["style"] as? [String: Any])
        if let stroke = styleG?["stroke"] as? [String: Any] {
            n.borderWidth = dbl(stroke["width"]) ?? 1
        }
        n.text = textRun(raw, type: type, style: styleG, input: input)

        // `controlBox` in the web renderer: 12pt of vertical padding around a
        // single 16pt body line. One line, always — a text field does not grow
        // with its placeholder.
        if type == "input" {
            let kind = (behavior?["input"] as? [String: Any])?["kind"] as? String ?? "text"
            if kind != "toggle" && kind != "slider" {
                let body = TYPE_RAMP["body"]!
                n.controlHeight = 2 * 12 + lu(body.size * body.lineHeight)
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
    private static func ownState(_ behavior: [String: Any]?, input: LayoutInput) -> String? {
        guard let b = behavior else { return nil }
        if let step = b["step"] as? [String: Any], let idx = (step["index"] as? NSNumber)?.intValue {
            let current = Int(input.variables["__stepIndex"] ?? "0") ?? 0
            if idx < current { return "completed" }
            if idx == current { return "current" }
            return "upcoming"
        }
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

        let text = plainText(props, input: input)
        guard !text.isEmpty else { return nil }
        let t = style?["text"] as? [String: Any]
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
                lineHeight: dbl(s?["lineHeight"])
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
    private static func localized(_ v: Any?, _ input: LayoutInput) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any], let k = d["key"] as? String {
            // A key with no entry is left visible rather than blanked: an empty
            // string measures as nothing and the layout silently closes up,
            // where a visible key shows exactly which entry is missing.
            return input.catalog[k] ?? k
        }
        return ""
    }

    private static func interpolate(_ s: String, input: LayoutInput) -> String {
        var out = s
        for (k, v) in input.variables where k != "__stepIndex" {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        for (k, v) in input.selections {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }

    // MARK: - primitives

    private static func merge(_ base: [String: Any]?, _ delta: [String: Any]?) -> [String: Any]? {
        guard let d = delta else { return base }
        guard var b = base else { return d }
        for (k, v) in d { b[k] = v }
        return b
    }

    private static func dbl(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

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

/// The type ramp, which must equal `TYPE_RAMP` in `render/context.ts`.
struct Ramp { let size: Double; let weight: String; let lineHeight: Double }

let TYPE_RAMP: [String: Ramp] = [
    "display": Ramp(size: 34, weight: "bold", lineHeight: 1.15),
    "title": Ramp(size: 28, weight: "bold", lineHeight: 1.2),
    "subtitle": Ramp(size: 20, weight: "medium", lineHeight: 1.3),
    "body": Ramp(size: 16, weight: "regular", lineHeight: 1.45),
    "caption": Ramp(size: 13, weight: "regular", lineHeight: 1.4),
    "label": Ramp(size: 15, weight: "medium", lineHeight: 1.3),
]

let WEIGHTS: [String: Int] = [
    "light": 300, "regular": 400, "medium": 500,
    "semibold": 600, "bold": 700, "black": 900,
]
