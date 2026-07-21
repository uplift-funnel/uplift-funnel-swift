import Foundation
import SwiftUI

// Render context threaded through every renderNode call, ported from the
// Flutter SDK's `primitive_renderer.dart`. Carries the theme, active locale
// + localization catalog, interpolation vars, and the action/save callbacks
// that wire interaction back to the host.

/// Type-ramp entry (Spec v2 §4): role → (size, lineHeight multiplier, weight).
struct RampEntry {
    let size: Double
    let lineHeight: Double
    let weight: Font.Weight
}

let typeRamp: [String: RampEntry] = [
    "display": RampEntry(size: 34, lineHeight: 1.1, weight: .bold),
    "title": RampEntry(size: 26, lineHeight: 1.15, weight: .bold),
    "subtitle": RampEntry(size: 19, lineHeight: 1.3, weight: .medium),
    "body": RampEntry(size: 16, lineHeight: 1.45, weight: .regular),
    "caption": RampEntry(size: 13, lineHeight: 1.4, weight: .regular),
    "label": RampEntry(size: 14, lineHeight: 1.2, weight: .medium),
]

func fontWeight(from w: String?, fallback: Font.Weight) -> Font.Weight {
    switch w {
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return fallback
    }
}

/// Parsed `screen.style` (ScreenStyle in the schema): per-screen design
/// overrides the SDK applies through RenderCtx. All defaults are identity.
/// (`background` is consumed separately by the screen background layers.)
struct ScreenStyleOverrides {
    /// Raw CSS color overriding `primary`/`accent` token lookups.
    var accent: String?
    var cornerRadiusScale: Double = 1
    var fontSizeScale: Double = 1
    /// Overrides heading (title/display) weight.
    var fontWeight: String?
    var paddingScale: Double = 1
    /// Default CTA variant when a button node doesn't set one.
    var buttonVariant: String?
    /// Default text alignment when a text node doesn't set one.
    var textAlign: String?
    /// Per-screen default font family (alias or verbatim family).
    var fontFamily: String?

    init() {}

    init(style: JSONValue) {
        guard style.objectValue?.isEmpty == false else { return }
        accent = style["accent"].stringValue
        cornerRadiusScale = style["corner_radius_scale"].doubleValue ?? 1
        fontSizeScale = style["font_size_scale"].doubleValue ?? 1
        fontWeight = style["font_weight"].stringValue
        paddingScale = style["padding_scale"].doubleValue ?? 1
        buttonVariant = style["button_variant"].stringValue
        textAlign = style["text_align"].stringValue
        fontFamily = style["font_family"].stringValue
    }
}

struct RenderCtx {
    var theme: PrimTheme
    var screenStyle = ScreenStyleOverrides()

    /// When true, motion is suppressed: pulse CTAs render static and video
    /// nodes fall back to their poster/placeholder.
    var reduceMotion = false

    var locale: String
    var defaultLocale: String
    var localizations: JSONValue
    var vars: [String: String]

    /// Live selection/input state for smart nodes: `save_to` → stringified
    /// value. Read by `boundValue`; written via `onSave`.
    var selections: [String: String] = [:]

    /// Axis of the enclosing stack — lets nested sizing decisions know the
    /// main axis (row vs column).
    var parentAxis: Axis = .vertical

    /// Called for a `button.action` or a `choice` auto-advance.
    var onAction: ((String) -> Void)?

    /// Called when a smart node writes a value: (save_to, value).
    var onSave: ((String, String) -> Void)?

    /// Native auth handoff for a `signin` node. Nil (previews, tests) means
    /// the tap is treated as an immediate success.
    var onSignIn: ((String) async -> Bool)?

    /// Native OS-permission handoff for a `permission` node. Nil =
    /// immediate mock grant.
    var onPermission: ((String) async -> Bool)?

    /// Host photo picker for `photo_upload` nodes; nil renders an inert tile.
    var onPhotoUpload: ((PhotoUploadRequest) async -> String?)?

    /// Native billing handoff for the `purchase` button action: receives
    /// the selected plan id (from `planSaveTo`) and resolves to success.
    /// Nil = `purchase` just advances (paywall inert until billing wired).
    var onPurchase: ((String?) async -> Bool)?

    /// Native restore-purchases handoff for the `restore` button action.
    /// Nil, or a false result, means `restore` no-ops rather than advancing.
    var onRestore: (() async -> Bool)?

    /// `bind.save_to` of the screen's first `plan_picker`, if any — where
    /// the `purchase` action reads the selected plan id from.
    var planSaveTo: String?

    func resolve(_ ls: JSONValue) -> String {
        resolveString(
            ls, locale: locale, localizations: localizations,
            defaultLocale: defaultLocale, vars: vars)
    }

    /// Current value of a bound variable, from live selections then vars.
    func boundValue(_ saveTo: String?) -> String? {
        guard let saveTo else { return nil }
        return selections[saveTo] ?? vars[saveTo]
    }

    /// Whether a node gated by `enabled_when` should be interactive.
    ///
    /// Reads through the same precedence as `boundValue` — live selections
    /// first, then session variables — so a CTA gating on the choice
    /// directly above it reacts as soon as that choice is made. A malformed
    /// or non-comparable condition enables the node: an authoring mistake
    /// must not strand the user on a screen with no way forward.
    func isEnabled(_ enabledWhen: JSONValue) -> Bool {
        guard enabledWhen.objectValue != nil else { return true }
        guard let condition = try? FunnelCondition(json: enabledWhen) else {
            return true
        }
        do {
            return try evaluateCondition(condition) { name in
                let raw: String?
                if name.contains(".") {
                    raw = vars[name]
                } else {
                    raw = boundValue(name) ?? vars[name]
                }
                return raw.map { JSONValue.string($0) }
            }
        } catch {
            return true
        }
    }

    /// Bound value decoded as a list: a JSON-array string (`["a","b"]` —
    /// the canonical multi-select encoding) round-trips, a plain scalar
    /// reads as a 1-element list, absent reads as empty.
    func boundValues(_ saveTo: String?) -> [String] {
        guard let raw = boundValue(saveTo), !raw.isEmpty else { return [] }
        if raw.hasPrefix("["),
           let decoded = try? JSONValue.parse(raw),
           let list = decoded.arrayValue {
            return list.map { $0.stringifiedValue ?? $0.serializedString() }
        }
        return [raw]
    }

    func writeVar(_ saveTo: String?, _ value: String) {
        guard let saveTo else { return }
        onSave?(saveTo, value)
    }

    /// Runs a button-style action string. `purchase`/`restore` are native
    /// handoffs (not transitions): `purchase` runs `onPurchase` with the
    /// selected plan and advances only on success (no handler ⇒ plain
    /// advance); `restore` runs `onRestore` and advances only when it
    /// returns true. Everything else routes to `onAction`. Shared by the
    /// button tap AND markdown action-links (`[Restore](restore)`) so the
    /// two can never drift.
    func dispatchAction(_ action: String) async {
        if action == "purchase" {
            if let handler = onPurchase {
                let ok = await handler(boundValue(planSaveTo))
                if !ok { return }
            }
            onAction?("next")
            return
        }
        if action == "restore" {
            guard let handler = onRestore else { return }
            let restored = await handler()
            if restored { onAction?("next") }
            return
        }
        onAction?(action)
    }

    /// Resolve a TokenRef: a theme color-token name or a raw #hex/CSS
    /// color. A screen-level `style.accent` override wins for
    /// `primary`/`accent` lookups.
    func color(_ ref: String?, fallback: RGBAColor = .transparent) -> RGBAColor {
        guard let ref, !ref.isEmpty else { return fallback }
        if let accent = screenStyle.accent, ref == "primary" || ref == "accent" {
            return parseCssColor(accent) ?? fallback
        }
        let token = theme.colors[ref]
        return parseCssColor(token ?? ref) ?? fallback
    }

    // Palette shorthands with the reference defaults (mirror DEFAULT_PALETTE).
    var primary: RGBAColor { color("primary", fallback: RGBAColor(hex: 0x16A34A)) }
    var accent: RGBAColor { color("accent", fallback: primary) }
    var surface: RGBAColor { color("surface", fallback: RGBAColor(hex: 0xF4F4F5)) }
    var border: RGBAColor { color("border", fallback: RGBAColor(hex: 0xE4E4E7)) }
    var textPrimary: RGBAColor { color("text_primary", fallback: RGBAColor(hex: 0x0A0A0A)) }
    var textSecondary: RGBAColor { color("text_secondary", fallback: RGBAColor(hex: 0x71717A)) }
    var errorColor: RGBAColor { color("error", fallback: RGBAColor(hex: 0xDC2626)) }
    var success: RGBAColor { color("success", fallback: primary) }
    var background: RGBAColor { color("background", fallback: .white) }

    /// On-primary text color for filled buttons (dark text on light primary).
    var onPrimary: RGBAColor { primary.isLight ? RGBAColor(hex: 0x0A0A0A) : .white }

    var unit: Double { theme.spacingUnit }
    var cornerRadius: Double { theme.cornerRadius * screenStyle.cornerRadiusScale }

    /// Type-ramp lookup with the screen's `font_size_scale` applied, and
    /// `font_weight` overriding heading roles. Renderers MUST size text
    /// through this, not `typeRamp` directly.
    func ramp(_ role: String) -> RampEntry {
        let entry = typeRamp[role] ?? typeRamp["body"]!
        let scale = screenStyle.fontSizeScale
        let weightOverride = screenStyle.fontWeight
        let isHeading = role == "title" || role == "display"
        if scale == 1 && (weightOverride == nil || !isHeading) { return entry }
        return RampEntry(
            size: entry.size * scale,
            lineHeight: entry.lineHeight,
            weight: isHeading && weightOverride != nil
                ? fontWeight(from: weightOverride, fallback: entry.weight)
                : entry.weight)
    }

    /// Copy of this context for recursing into a child container.
    func withParentAxis(_ axis: Axis) -> RenderCtx {
        var copy = self
        copy.parentAxis = axis
        return copy
    }
}

/// Builds a SwiftUI Font from schema family/size/weight/italic.
func primFont(
    family: ResolvedFontFamily, size: Double, weight: Font.Weight,
    italic: Bool = false
) -> Font {
    var font: Font
    switch family {
    case .system:
        font = .system(size: size, weight: weight)
    case .serif:
        font = .system(size: size, weight: weight, design: .serif)
    case .mono:
        font = .system(size: size, weight: weight, design: .monospaced)
    case .custom(let name):
        font = .custom(name, size: size).weight(weight)
    }
    if italic { font = font.italic() }
    return font
}

/// Per-node `style.fontFamily` override, else the screen default, else the
/// theme family.
func resolveNodeFontFamily(_ override: String?, _ ctx: RenderCtx) -> ResolvedFontFamily {
    let raw = override
        ?? (ctx.theme.fontFamily == "system" ? nil : ctx.theme.fontFamily)
    return resolveFontFamilyAlias(raw)
}
