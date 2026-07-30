/// How the layout engine asks for text metrics without knowing how text works.
///
/// The engine cannot shape text — it must not import CoreText, and on another
/// platform the shaper is something else entirely. So it states the question and
/// takes an answer: given this run and this available width, how many lines,
/// where do they break, and how big is the result.
///
/// The indirection also buys the thing that makes parity debuggable. There are
/// two ways the iOS renderer can disagree with the browser: the boxes are
/// wrong, or the text is. Those have completely different causes and completely
/// different fixes, and a single failing screenshot cannot tell them apart. With
/// a measurer as a seam, the same solver runs twice — once against Chromium's
/// own recorded metrics, where any mismatch is the solver's fault, and once
/// against CoreText, where a new mismatch is the shaper's. The failure names its
/// own cause.

public struct TextRunSpec: Equatable, Sendable {
    public var text: String
    /// Points, already resolved through the type ramp.
    public var fontSize: Double
    /// CSS numeric weight, 100–900. Not a `UIFont.Weight`: SF's named instances
    /// do not sit at the CSS positions, and snapping to them is wrong by up to
    /// 8.86pt on a heading. The shaper drives the variable `wght` axis instead.
    public var fontWeight: Int
    public var letterSpacing: Double
    /// Multiplier over the resolved font size, or nil for the font's own.
    public var lineHeight: Double?
    /// nil means unconstrained — measure on one line.
    public var maxWidth: Double?

    public init(
        text: String,
        fontSize: Double,
        fontWeight: Int = 400,
        letterSpacing: Double = 0,
        lineHeight: Double? = nil,
        maxWidth: Double? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
        self.maxWidth = maxWidth
    }
}

public struct TextLine: Equatable, Sendable {
    public var text: String
    public var width: Double

    public init(text: String, width: Double) {
        self.text = text
        self.width = width
    }
}

public struct TextMetrics: Equatable, Sendable {
    public var lines: [TextLine]
    /// The widest line — a text node's intrinsic width at this constraint.
    public var width: Double
    public var height: Double

    public init(lines: [TextLine], width: Double, height: Double) {
        self.lines = lines
        self.width = width
        self.height = height
    }
}

public protocol TextMeasuring: Sendable {
    func measure(_ run: TextRunSpec) -> TextMetrics
    /// The width below which the run cannot be squeezed — its longest
    /// unbreakable word. CSS calls this min-content, and a row's shrink floor
    /// depends on it: an unbreakable `{{product.price}}` setting a row's
    /// min-content width is what squeezed a sibling to zero in the web
    /// renderer before it was fixed.
    func minContentWidth(_ run: TextRunSpec) -> Double
}
