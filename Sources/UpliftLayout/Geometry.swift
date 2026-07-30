/// Geometry for the layout engine.
///
/// Deliberately its own types rather than CoreGraphics': this target must not
/// import a framework, so that the same code can be read as the specification
/// by the Dart and Kotlin renderers and unit-tested without a view hierarchy.

public struct Size2D: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size2D(width: 0, height: 0)
}

public struct Point2D: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)
}

public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var size: Size2D { Size2D(width: width, height: height) }
    public var origin: Point2D { Point2D(x: x, y: y) }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)
}

/// Insets in the order the schema writes them: top, right, bottom, left.
public struct Edges: Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static let zero = Edges()

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }
}

// MARK: - LayoutUnit

/// One sixty-fourth of a point — the grid every layout length lands on.
///
/// This is not a rounding convenience. Chromium stores every layout length as a
/// `LayoutUnit`, a fixed-point integer of 1/64px, and FLOORS toward negative
/// infinity when converting. The reference frames show it plainly: a card top at
/// `413.046875` is 413 + 3/64, and a line width of `94.453125` is 94 + 29/64.
///
/// It has to be applied from the first line rather than retrofitted. The error
/// per site is under a sixty-fourth of a point, which sounds ignorable and is
/// not: it accumulates down a column, so ten stacked text lines drift an eighth
/// of a point and the eleventh child sits visibly wrong. Every place that
/// resolves a size or an offset passes through here.
@inline(__always)
public func lu(_ value: Double) -> Double {
    (value * 64).rounded(.down) / 64
}

/// The same grid, rounded UP — for intrinsic sizes only.
///
/// A hug width is a promise that the content fits, and flooring breaks the
/// promise: a run measuring 68.8823 floors to 68.875, the box is then a
/// hundredth of a point narrower than the text it was sized for, and the text
/// wraps to two lines inside the box built to hold it on one. The observed
/// failures were exactly that — 68.875 against Chromium's 68.8906, one unit
/// apart, with double the height.
///
/// Chromium does not have this problem because it does not floor here.
/// `LayoutUnit::FromFloatCeil` is what Blink resolves min/max-content with, for
/// this reason. Positions and final frames still floor; only the question "how
/// much room does this content need" rounds the other way.
@inline(__always)
public func luCeil(_ value: Double) -> Double {
    (value * 64).rounded(.up) / 64
}

public extension Size2D {
    /// Both axes on the layout grid.
    var quantised: Size2D { Size2D(width: lu(width), height: lu(height)) }
}

public extension Rect {
    var quantised: Rect { Rect(x: lu(x), y: lu(y), width: lu(width), height: lu(height)) }
}
