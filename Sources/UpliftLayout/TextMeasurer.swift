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

/// One stretch of a run with its own typography.
///
/// A price reads "€8.99" large beside "/ week" small, an old price is struck
/// through inline, a headline changes colour mid-sentence. These are INLINE
/// boxes on one line box — not a row of text nodes, which is what v2 needed and
/// which broke the moment the line wrapped.
public struct TextSegment: Equatable, Sendable {
    public var text: String
    public var fontSize: Double
    public var fontWeight: Int
    public var letterSpacing: Double
    /// Multiplier over THIS segment's size. A span that does not name one
    /// inherits the node's, and the node's is unitless — so a 22pt span under a
    /// 1.45 node gets a 31.9pt line box, not the node's 23.2.
    public var lineHeight: Double?

    public init(
        text: String,
        fontSize: Double,
        fontWeight: Int = 400,
        letterSpacing: Double = 0,
        lineHeight: Double? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
    }
}

public struct TextRunSpec: Equatable, Sendable {
    public var text: String
    /// The run split into differently-styled stretches, or nil when it is
    /// uniform. `text` stays the joined string either way, so a measurer that
    /// does not care can ignore this entirely.
    ///
    /// The node's own typography is still the STRUT — it sets the floor for the
    /// line box even when every span is smaller, which is why it is kept
    /// alongside rather than replaced by the segments.
    public var spans: [TextSegment]?
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
        maxWidth: Double? = nil,
        spans: [TextSegment]? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
        self.maxWidth = maxWidth
        self.spans = spans
    }

    /// The run as segments, uniform runs included — one segment carrying the
    /// node's own typography. Lets a measurer have a single code path.
    public var resolvedSpans: [TextSegment] {
        spans ?? [TextSegment(
            text: text,
            fontSize: fontSize,
            fontWeight: fontWeight,
            letterSpacing: letterSpacing,
            lineHeight: lineHeight
        )]
    }

    /// The line box this run occupies, in points.
    ///
    /// CSS takes the tallest inline box on the line, and the block's own font is
    /// one of the candidates — the strut — even when no text uses it. A price
    /// node with no typography of its own still struts at the body ramp; its
    /// 22pt spans simply out-vote it.
    public var lineBox: Double {
        let strut = lineHeight.map { lu(fontSize * $0) } ?? 0
        return resolvedSpans.reduce(strut) { tallest, span in
            let multiplier = span.lineHeight ?? lineHeight
            guard let multiplier else { return tallest }
            return max(tallest, lu(span.fontSize * multiplier))
        }
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
