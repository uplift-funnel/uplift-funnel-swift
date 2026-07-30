/// What a node looks like, as data.
///
/// Deliberately in the layout target and deliberately free of CoreGraphics: the
/// painter that consumes this is one file per platform, and everything upstream
/// of it — decoding the document, resolving the palette, resolving states,
/// composing transforms — is shared arithmetic that can be unit-tested without a
/// drawing context. The same reasoning that keeps `FlexSolver` out of SwiftUI.
///
/// The vocabulary is the web renderer's, because that file is the parity
/// reference. Where CSS has a shorthand this has a struct, and where CSS has a
/// default this states it.

/// A colour with straight (non-premultiplied) alpha, 0…1 per channel.
public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 1, g: 1, b: 1)

    /// A document colour: a theme token, a hex string, or `rgba()`.
    ///
    /// Tokens first, exactly as `resolveColor` does on the web — a node saying
    /// `"primary"` must pick up the flow's own palette, not a colour named
    /// primary. Anything unrecognised returns nil rather than a guess: a
    /// silently-black box is much harder to notice than a missing one.
    public static func parse(_ raw: String?, tokens: [String: String] = [:]) -> RGBA? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let token = tokens[s] { s = token }

        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            func byte(_ i: Int, _ len: Int) -> Double? {
                let chars = Array(hex)
                guard chars.count >= (i + 1) * len else { return nil }
                let slice = String(chars[(i * len)..<((i + 1) * len)])
                // #RGB is shorthand for #RRGGBB — each digit doubled.
                let full = len == 1 ? slice + slice : slice
                guard let v = UInt8(full, radix: 16) else { return nil }
                return Double(v) / 255
            }
            switch hex.count {
            case 3, 4:
                guard let r = byte(0, 1), let g = byte(1, 1), let b = byte(2, 1) else { return nil }
                return RGBA(r: r, g: g, b: b, a: hex.count == 4 ? (byte(3, 1) ?? 1) : 1)
            case 6, 8:
                guard let r = byte(0, 2), let g = byte(1, 2), let b = byte(2, 2) else { return nil }
                return RGBA(r: r, g: g, b: b, a: hex.count == 8 ? (byte(3, 2) ?? 1) : 1)
            default:
                return nil
            }
        }

        if s.hasPrefix("rgb") {
            let inner = s.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            return RGBA(
                r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255,
                a: parts.count > 3 ? parts[3] : 1
            )
        }

        switch s {
        case "transparent", "none": return .clear
        case "black": return .black
        case "white": return .white
        default: return nil
        }
    }
}

/// Where a gradient's colour sits, 0…1 along the run.
public struct GradientStop: Equatable, Sendable {
    public var color: RGBA
    public var at: Double

    public init(color: RGBA, at: Double) {
        self.color = color
        self.at = at
    }
}

public enum ImageFit: String, Equatable, Sendable {
    case cover, contain, fill, tile
}

public enum Paint: Equatable, Sendable {
    case flat(RGBA)
    /// Degrees clockwise from "to top", matching CSS.
    case linear(angle: Double, stops: [GradientStop])
    /// Centre and radius in fractions of the box.
    case radial(center: Point2D, radius: Double, stops: [GradientStop])
    case image(url: String, fit: ImageFit, position: Point2D, opacity: Double)
}

public enum StrokeAlign: String, Equatable, Sendable {
    /// Eats into the content box, which is what `box-sizing: border-box` does
    /// and what the solver already accounts for in `LayoutNode.borderWidth`.
    case inside
    /// Painted beyond the bounds, affecting nothing — the web draws it as a
    /// spread-only box-shadow ring for exactly that reason.
    case outside
}

public struct Stroke: Equatable, Sendable {
    public var color: RGBA
    public var width: Edges
    public var align: StrokeAlign
    public var dash: [Double]?

    public init(color: RGBA, width: Edges, align: StrokeAlign = .inside, dash: [Double]? = nil) {
        self.color = color
        self.width = width
        self.align = align
        self.dash = dash
    }
}

/// Per-corner radii, in the CSS order: top-left, top-right, bottom-right,
/// bottom-left.
public struct Corners: Equatable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public init(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init(_ all: Double) {
        self.init(topLeft: all, topRight: all, bottomRight: all, bottomLeft: all)
    }

    public static let none = Corners(0)
    public var isSquare: Bool { self == .none }

    /// Radii clamped so opposite corners cannot overlap.
    ///
    /// A `corner: 999` pill on a 44pt-tall button is the corpus's normal way of
    /// saying "fully round", and drawing it literally produces a self-
    /// intersecting path. CSS scales every radius by the same factor so the
    /// shape stays proportional rather than clamping each corner separately.
    public func fitted(in size: Size2D) -> Corners {
        let factors = [
            (topLeft + topRight) > 0 ? size.width / (topLeft + topRight) : .infinity,
            (bottomLeft + bottomRight) > 0 ? size.width / (bottomLeft + bottomRight) : .infinity,
            (topLeft + bottomLeft) > 0 ? size.height / (topLeft + bottomLeft) : .infinity,
            (topRight + bottomRight) > 0 ? size.height / (topRight + bottomRight) : .infinity,
        ]
        let f = min(1, factors.min() ?? 1)
        guard f < 1 else { return self }
        return Corners(
            topLeft: topLeft * f, topRight: topRight * f,
            bottomRight: bottomRight * f, bottomLeft: bottomLeft * f
        )
    }
}

public struct Shadow: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var blur: Double
    public var spread: Double
    public var color: RGBA
    public var inset: Bool

    public init(
        x: Double = 0, y: Double = 0, blur: Double, spread: Double = 0,
        color: RGBA, inset: Bool = false
    ) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
        self.inset = inset
    }
}

/// `translate` then `rotate` then `scale`, applied about the node's centre.
public struct Transform2D: Equatable, Sendable {
    public var translate: Point2D
    public var rotate: Double
    public var scale: Double

    public init(translate: Point2D = .zero, rotate: Double = 0, scale: Double = 1) {
        self.translate = translate
        self.rotate = rotate
        self.scale = scale
    }

    public static let identity = Transform2D()
    public var isIdentity: Bool { self == .identity }
}

public struct PaintStyle: Equatable, Sendable {
    public var fill: Paint?
    public var stroke: Stroke?
    public var corners: Corners
    public var shadows: [Shadow]
    public var opacity: Double
    public var transform: Transform2D
    /// The blur the schema calls `backdropBlur`, kept so a decode is lossless
    /// even though the painter refuses it — see `PaintUnsupported`.
    public var backdropBlur: Double?

    public init(
        fill: Paint? = nil,
        stroke: Stroke? = nil,
        corners: Corners = .none,
        shadows: [Shadow] = [],
        opacity: Double = 1,
        transform: Transform2D = .identity,
        backdropBlur: Double? = nil
    ) {
        self.fill = fill
        self.stroke = stroke
        self.corners = corners
        self.shadows = shadows
        self.opacity = opacity
        self.transform = transform
        self.backdropBlur = backdropBlur
    }

    public static let none = PaintStyle()
    /// Nothing to draw — no fill, no stroke, no shadow, fully opaque.
    public var isInvisible: Bool {
        fill == nil && stroke == nil && shadows.isEmpty
    }
}
