import Foundation
import SwiftUI

// NodeStyle helpers (Spec v2 §5), ported from `primitive_renderer.dart`.

/// Reads a CornerRadius (number, or [tl,tr,br,bl] in CSS border-radius
/// order). Values are px, NOT ×unit — schema parity.
struct CornerRadii: Equatable {
    var topLeft: Double
    var topRight: Double
    var bottomRight: Double
    var bottomLeft: Double

    init(all: Double) {
        topLeft = all; topRight = all; bottomRight = all; bottomLeft = all
    }

    init(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    static func parse(_ v: JSONValue) -> CornerRadii? {
        if let n = v.doubleValue, v.stringValue == nil {
            return CornerRadii(all: n)
        }
        if let list = v.arrayValue, list.count == 4 {
            let r = list.map { $0.doubleValue ?? 0 }
            return CornerRadii(
                topLeft: r[0], topRight: r[1], bottomRight: r[2], bottomLeft: r[3])
        }
        return nil
    }

    var isUniform: Bool {
        topLeft == topRight && topRight == bottomRight && bottomRight == bottomLeft
    }
}

/// Per-corner rounded rectangle usable on iOS 15 (UnevenRoundedRectangle is
/// 16.4+). Insettable so `strokeBorder` works.
struct RoundedCornersShape: InsettableShape {
    let radii: CornerRadii
    var insetAmount: CGFloat = 0

    init(radii: CornerRadii) {
        self.radii = radii
    }

    private init(radii: CornerRadii, insetAmount: CGFloat) {
        self.radii = radii
        self.insetAmount = insetAmount
    }

    func inset(by amount: CGFloat) -> RoundedCornersShape {
        RoundedCornersShape(radii: radii, insetAmount: insetAmount + amount)
    }

    func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: insetAmount, dy: insetAmount)
        var path = Path()
        let tl = min(radii.topLeft, min(rect.width, rect.height) / 2)
        let tr = min(radii.topRight, min(rect.width, rect.height) / 2)
        let br = min(radii.bottomRight, min(rect.width, rect.height) / 2)
        let bl = min(radii.bottomLeft, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0),
            clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br, startAngle: .degrees(0), endAngle: .degrees(90),
            clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl, startAngle: .degrees(90), endAngle: .degrees(180),
            clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl, startAngle: .degrees(180), endAngle: .degrees(270),
            clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Reads a SpaceValue (number or [t,r,b,l]) as EdgeInsets. Values are
/// logical px 1:1 — no theme.spacing.unit multiplier (a 24 in the editor is
/// 24px on device).
func spacingInsets(_ v: JSONValue) -> EdgeInsets? {
    if let n = v.doubleValue, v.stringValue == nil {
        return EdgeInsets(top: n, leading: n, bottom: n, trailing: n)
    }
    if let list = v.arrayValue, list.count == 4 {
        let vals = list.map { $0.doubleValue ?? 0 }
        // Schema order [t, r, b, l].
        return EdgeInsets(top: vals[0], leading: vals[3], bottom: vals[2], trailing: vals[1])
    }
    return nil
}

func scaleInsets(_ insets: EdgeInsets, by factor: Double) -> EdgeInsets {
    EdgeInsets(
        top: insets.top * factor, leading: insets.leading * factor,
        bottom: insets.bottom * factor, trailing: insets.trailing * factor)
}

struct BoxShadowSpec {
    let color: RGBAColor
    let blur: Double
    let x: Double
    let y: Double
}

func shadowSpecs(_ kind: String?) -> [BoxShadowSpec] {
    switch kind {
    case "soft":
        return [BoxShadowSpec(color: RGBAColor.black.opacity(0.06), blur: 12, x: 0, y: 4)]
    case "hard":
        return [
            BoxShadowSpec(color: RGBAColor.black.opacity(0.18), blur: 4, x: 0, y: 2),
            BoxShadowSpec(color: RGBAColor.black.opacity(0.10), blur: 16, x: 0, y: 8),
        ]
    default:
        return []
    }
}

/// A NodeStyle width/height value → concrete px, infinity for "fill", or
/// nil ("hug"/absent).
func dimensionValue(_ v: JSONValue) -> Double? {
    if v.stringValue == "fill" { return .infinity }
    if v.stringValue == nil, let n = v.doubleValue { return n }
    return nil
}

func swiftTextAlign(_ a: String?) -> TextAlignment {
    switch a {
    case "center": return .center
    case "end": return .trailing
    default: return .leading
    }
}

func frameAlignment(_ a: String?) -> Alignment {
    switch a {
    case "center": return .center
    case "end": return .trailing
    default: return .leading
    }
}

/// Wraps `view` in padding / background / border / radius / shadow / margin
/// / opacity from the node's `style`. Returns it untouched when empty.
/// Modifier order mirrors the Flutter Container composition.
func applyStyle<V: View>(_ view: V, _ style: JSONValue, _ ctx: RenderCtx) -> AnyView {
    guard let styleObj = style.objectValue, !styleObj.isEmpty else {
        return AnyView(view)
    }
    var out = AnyView(view)

    // Screen-level `padding_scale` multiplies every node's authored padding.
    var padding = spacingInsets(style["padding"])
    if let p = padding, ctx.screenStyle.paddingScale != 1 {
        padding = scaleInsets(p, by: ctx.screenStyle.paddingScale)
    }
    let bg = style["background"].stringValue
    let radii = CornerRadii.parse(style["radius"])
    let borderObj = style["border"].objectValue
    let shadowKind = style["shadow"].stringValue

    let hasBox = bg != nil || radii != nil || borderObj != nil
        || (shadowKind != nil && shadowKind != "none")

    if let padding, !hasBox {
        out = AnyView(out.padding(padding))
    } else if hasBox || padding != nil {
        if let padding { out = AnyView(out.padding(padding)) }

        let shape = RoundedCornersShape(radii: radii ?? CornerRadii(all: 0))

        // A raw CSS gradient string paints as a real gradient; token names
        // and flat colors go through the usual TokenRef resolution.
        if let bg {
            let gradientBg = ctx.theme.colors[bg] == nil ? CssBackground.parse(bg) : nil
            if let gradient = gradientBg?.swiftUIGradient {
                out = AnyView(out.background(gradient))
            } else {
                out = AnyView(out.background(ctx.color(bg).color))
            }
        }
        if radii != nil {
            out = AnyView(out.clipShape(shape))
        }
        if let borderObj {
            let color = ctx.color(
                JSONValue.object(borderObj)["color"].stringValue,
                fallback: RGBAColor(hex: 0xE4E4E7))
            let width = JSONValue.object(borderObj)["width"].doubleValue ?? 1
            out = AnyView(out.overlay(
                shape.strokeBorder(color.color, lineWidth: width)))
        }
        for spec in shadowSpecs(shadowKind) {
            out = AnyView(out.shadow(
                color: spec.color.color, radius: spec.blur / 2,
                x: spec.x, y: spec.y))
        }
    }

    if let margin = spacingInsets(style["margin"]) {
        out = AnyView(out.padding(margin))
    }

    if let opacity = style["opacity"].doubleValue, style["opacity"].stringValue == nil {
        out = AnyView(out.opacity(opacity))
    }

    let w = dimensionValue(style["width"])
    let h = dimensionValue(style["height"])
    let widthPx: CGFloat? = (w != nil && w!.isFinite) ? CGFloat(w!) : nil
    let heightPx: CGFloat? = (h != nil && h!.isFinite) ? CGFloat(h!) : nil
    if widthPx != nil || heightPx != nil {
        out = AnyView(out.frame(width: widthPx, height: heightPx))
    }
    if w == .infinity || h == .infinity {
        out = AnyView(out.frame(
            maxWidth: w == .infinity ? .infinity : nil,
            maxHeight: h == .infinity ? .infinity : nil))
    }
    return out
}

// MARK: - Named icons

/// Named icons resolve to SF Symbols — they scale, tint, and render
/// natively. Authors who want a specific emoji set `props.emoji` instead.
/// (Flutter maps the same names to Material glyphs.)
let namedIcons: [String: String] = [
    "check": "checkmark",
    "check_circle": "checkmark.circle.fill",
    "close": "xmark",
    "star": "star.fill",
    "heart": "heart.fill",
    "bolt": "bolt.fill",
    "lock": "lock",
    "bell": "bell",
    "camera": "camera",
    "fire": "flame.fill",
    "sparkles": "sparkles",
    "clock": "clock",
    "calendar": "calendar",
    "chart": "chart.line.uptrend.xyaxis",
    "target": "scope",
    "trophy": "rosette",
    "gift": "gift",
    "shield": "shield",
    "user": "person",
    "users": "person.2",
    "settings": "gearshape",
    "search": "magnifyingglass",
    "home": "house",
    "mail": "envelope",
    "phone": "phone",
    "location": "mappin.and.ellipse",
    "image": "photo",
    "video": "video",
    "music": "music.note",
    "book": "book",
    "run": "figure.walk",
    "meal": "fork.knife",
    "sleep": "bed.double",
    "water": "drop",
    "moon": "moon",
    "sun": "sun.max",
    "plus": "plus",
    "minus": "minus",
    "arrow_right": "arrow.right",
    "info": "info.circle",
    "warning": "exclamationmark.triangle",
]

/// Fallback glyph for an unknown icon name — a visible placeholder beats an
/// invisible gap when an author typos a name.
let unknownGlyph = "◆"

/// permission key → (emoji, default label).
let permissionMeta: [String: (emoji: String, label: String)] = [
    "camera": ("📷", "Camera"),
    "photos": ("🖼️", "Photos"),
    "health": ("❤️", "Health"),
    "location": ("📍", "Location"),
    "microphone": ("🎙️", "Microphone"),
    "contacts": ("👥", "Contacts"),
    "notifications": ("🔔", "Notifications"),
    "calendar": ("📅", "Calendar"),
    "tracking": ("📡", "Tracking"),
]
