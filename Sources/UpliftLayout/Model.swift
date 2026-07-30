/// The layout engine's view of a node.
///
/// Deliberately not the wire format and not the renderer's node. The engine
/// needs the five property groups reduced to the handful of facts that decide a
/// frame, with every state delta already applied and every invisible node
/// already gone — so it can be a pure function of a tree, and so the port to
/// Dart and Kotlin is a port of arithmetic rather than of a decoder.

public enum LayoutMode: String, Sendable {
    case column, row, wrap, grid, stack
}

public enum Position: String, Sendable {
    case relative, absolute, fixed
}

/// A size along one axis. `hug` is the absence of an instruction.
public enum Size: Equatable, Sendable {
    case hug
    case fill
    case points(Double)
    case percent(Double)
}

public enum Align: String, Sendable {
    case start, center, end, stretch
}

public enum ScrollAxis: String, Sendable, Equatable {
    case vertical, horizontal
}

public enum SnapAlign: String, Sendable, Equatable {
    case none, start, center
}

public struct LayoutNode: Sendable {
    /// Dotted child indices — "1.3.0" — matching the web renderer's
    /// `data-node-path`, which is what makes a parity failure name a node.
    public var path: String
    public var type: String

    // self
    public var position: Position = .relative
    public var width: Size = .hug
    public var height: Size = .hug
    public var grow: Double?
    public var inset: Edges?
    public var insetSides: (top: Bool, right: Bool, bottom: Bool, left: Bool) = (false, false, false, false)
    public var anchorX: Align?
    public var anchorY: Align?
    public var z: Int?
    public var ignoreSafeArea: Bool = false

    /// Border width, in points, on every edge.
    ///
    /// This is LAYOUT, not paint. The web renderer sets `box-sizing: border-box`
    /// on every node, so a border eats into the content box: raising a card's
    /// stroke from 1 to 2 moves its children in by a point and narrows them by
    /// two. That is exactly what the paywall's `selected` delta does, which is
    /// why a renderer that draws borders as an overlay cannot match it.
    public var borderWidth: Double = 0

    // layout
    public var mode: LayoutMode = .column
    public var padding: Edges = .zero
    public var gapMain: Double = 0
    public var alignX: Align?
    public var alignY: Align?

    // style — what the node looks like. Carried alongside the layout facts
    // rather than in a parallel tree, because a state delta re-resolves both at
    // once and splitting them would mean walking the document twice and hoping
    // the two walks agreed.
    public var paint: PaintStyle = .none

    /// Whether descendants are cut to this node's shape — `layout.clip`, and
    /// ONLY that.
    ///
    /// It used to mean "clip, or scroll" and the two were collapsed at decode:
    /// `clip ?? (scroll != nil)`. That threw away the axis, which is why 174pt
    /// of the paywall — the CTA included — was cut off, invisible and
    /// untappable, on a screen the document says scrolls.
    public var clipsContent: Bool = false

    /// The axis this node scrolls on, or nil.
    ///
    /// A scroller clips too, but on its CROSS axis only: a vertical scroller
    /// hides horizontal overflow and lets vertical overflow through, which is
    /// exactly what `overflow-y: auto; overflow-x: hidden` says on the web.
    public var scroll: ScrollAxis?
    /// Where a scrolled child comes to rest. Carried but not yet honoured —
    /// `scrollTargetBehavior` is iOS 17 and this package floors at 16.
    public var snap: SnapAlign?

    // leaf content, for the intrinsic pass
    public var text: TextRunSpec?
    public var textColor: RGBA?
    public var textAlign: TextAlign = .start
    /// `-webkit-line-clamp`: the run is truncated rather than laid out taller.
    public var maxLines: Int?
    public var image: (url: String, fit: ImageFit, position: Point2D)?

    /// A control's own text — an input's answer, or its placeholder when there
    /// is none.
    ///
    /// Separate from `text` because it must NOT size the box: a text field is
    /// one line whatever the placeholder says, and measuring it would make the
    /// field grow when the copy got longer. `controlHeight` already states the
    /// height; this only says what to paint inside it.
    public var controlText: TextRunSpec?

    /// A native control's own height, when the platform decides it rather than
    /// content does.
    ///
    /// An `input` is not measured text: it is one line whatever the placeholder
    /// says, and its height comes from the control's own padding and line box.
    /// Measuring the placeholder would make the field grow when the copy got
    /// longer, which no text field does.
    public var controlHeight: Double?

    public var children: [LayoutNode] = []

    public init(path: String, type: String) {
        self.path = path
        self.type = type
    }
}

/// What the engine is laying out into.
public struct Viewport: Sendable {
    /// The screen body, inside the chrome.
    public var size: Size2D
    /// The device insets the body already sits inside — a node carrying
    /// `ignoreSafeArea` escapes the top one.
    public var safeTop: Double

    public init(size: Size2D, safeTop: Double) {
        self.size = size
        self.safeTop = safeTop
    }
}

/// A node's solved frame, in the screen body's coordinates.
public struct SolvedFrame: Equatable, Sendable {
    public var path: String
    public var rect: Rect

    public init(path: String, rect: Rect) {
        self.path = path
        self.rect = rect
    }
}

/// What the solver refuses to guess at.
///
/// The corpus uses column, row and stack; `grid` and `wrap` are in the schema
/// and used by nothing yet. A solver that quietly treated them as a column
/// would produce a plausible wrong answer, and a plausible wrong answer in a
/// layout engine is worse than a loud refusal — it ships.
public enum LayoutUnsupported: Error, Equatable, Sendable {
    case mode(LayoutMode, path: String)
    case percentSize(path: String)
}
