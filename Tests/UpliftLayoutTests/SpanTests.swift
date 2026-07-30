import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// Spans as inline boxes, which is what they are.
///
/// A price reads "€8.99" large beside "/ week" small; an old price is struck
/// through inline; a headline changes colour mid-sentence. v2 needed a row of
/// separate text nodes for any of that, and the row broke the moment the line
/// wrapped. Modelling them as one run in the NODE's typography was the same
/// mistake in a different place: the paywall's price node has no `style.text`
/// at all, so the joined string was shaped at the 16pt body ramp and came out
/// 93.4pt where the browser gives 129.5.
final class SpanTests: XCTestCase {
    private let measurer = CoreTextMeasurer()

    private var price: TextRunSpec {
        TextRunSpec(
            text: "€8.99 / week",
            fontSize: 16, fontWeight: 400, letterSpacing: 0, lineHeight: 1.45,
            spans: [
                TextSegment(text: "€8.99", fontSize: 22, fontWeight: 700),
                TextSegment(text: " / week", fontSize: 22, fontWeight: 400),
            ]
        )
    }

    /// The node's width is the sum of its segments, each in its own font.
    func testWidthIsTheSumOfDifferentlyStyledSegments() {
        let got = measurer.maxContentWidth(price)
        // Chromium's own: 63.03125 + 66.421875.
        XCTAssertEqual(got, 129.453125, accuracy: 0.05)

        // And emphatically not the joined string in the node's own type, which
        // is what it used to be.
        let flattened = measurer.maxContentWidth(
            TextRunSpec(text: "€8.99 / week", fontSize: 16, fontWeight: 400, lineHeight: 1.45)
        )
        XCTAssertLessThan(flattened, 100, "the 16pt reading should be far narrower")
    }

    /// The line box is the TALLEST inline box, not the node's own.
    ///
    /// The node struts at the body ramp — 16 × 1.45 = 23.2 — and its 22pt spans
    /// out-vote it at 31.9. Taking the node's own would put every sibling below
    /// the price 8.7pt too high.
    func testLineBoxComesFromTheTallestSegment() {
        XCTAssertEqual(price.lineBox, lu(22 * 1.45), accuracy: 0.0001)
        XCTAssertEqual(measurer.measure(price).height, lu(22 * 1.45), accuracy: 0.05)
    }

    /// A span that names nothing keeps the node's typography.
    ///
    /// The renderer builds each span's CSS and then deletes size, weight and
    /// line-height again unless the span set them — so a span that only meant
    /// to change colour must not be restyled.
    func testAnUnstyledSpanInheritsTheNode() {
        let run = TextRunSpec(
            text: "one two", fontSize: 19, fontWeight: 700, lineHeight: 1.45,
            spans: [
                TextSegment(text: "one", fontSize: 19, fontWeight: 700),
                TextSegment(text: " two", fontSize: 19, fontWeight: 700),
            ]
        )
        let uniform = TextRunSpec(text: "one two", fontSize: 19, fontWeight: 700, lineHeight: 1.45)
        XCTAssertEqual(
            measurer.maxContentWidth(run), measurer.maxContentWidth(uniform), accuracy: 0.0001,
            "spans that match the node should measure exactly as the node does"
        )
    }

    /// Breaking runs ACROSS a span boundary, because CoreText shapes mixed
    /// attributes as one paragraph.
    ///
    /// Summing per-span widths would agree with this only while the run fits on
    /// one line, and the corpus is one card-width away from not fitting.
    func testWrappingCrossesSpanBoundaries() {
        let long = TextRunSpec(
            text: "Save 40% every single month",
            fontSize: 16, fontWeight: 400, lineHeight: 1.45,
            spans: [
                TextSegment(text: "Save 40%", fontSize: 22, fontWeight: 700),
                TextSegment(text: " every single month", fontSize: 16, fontWeight: 400),
            ]
        )
        var narrow = long
        narrow.maxWidth = 120
        let laid = measurer.measure(narrow)
        XCTAssertGreaterThan(laid.lines.count, 1, "it should have wrapped at 120pt")
        for line in laid.lines {
            XCTAssertLessThanOrEqual(line.width, 120.5, "a line overflowed its box: \(line.text)")
        }
        // A break landed inside the second span rather than at the boundary,
        // which is only possible if the two were typeset together.
        XCTAssertTrue(
            laid.lines.contains { $0.text.contains("every") && !$0.text.hasPrefix(" every") },
            "expected a break inside a span, got \(laid.lines.map(\.text))"
        )
    }

    /// The decoder reads `props.spans`, resolving each against the node.
    func testDecoderBuildsSegmentsFromTheDocument() throws {
        let node: [String: Any] = [
            "type": "text",
            "props": ["spans": [
                ["text": "{{product.price}}", "style": ["size": 22, "weight": "bold"]],
                ["text": " / {{product.period}}", "style": ["size": 22, "weight": "regular"]],
            ]],
        ]
        // Under a node carrying the product ref, which is what puts
        // `{{product.price}}` in scope — a price span outside one has nothing
        // to interpolate against.
        let card: [String: Any] = [
            "type": "box",
            "behavior": ["product": ["ref": "weekly"]],
            "children": [node],
        ]
        let flow: [String: Any] = [
            "screens": [["root": ["type": "box", "children": [card]]]],
        ]
        let tree = try XCTUnwrap(Decoder.layoutTree(
            flow: flow, screenIndex: 0, locale: nil,
            input: LayoutInput(products: ["weekly": ["price": "€8.99", "period": "week"]])
        ))
        let run = try XCTUnwrap(tree.children.first?.children.first?.text)
        let spans = try XCTUnwrap(run.spans)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].fontSize, 22)
        XCTAssertEqual(spans[0].fontWeight, 700)
        XCTAssertEqual(spans[1].fontWeight, 400)
        // The joined text stays the run's own, so a measurer that ignores
        // segments still has something to shape.
        XCTAssertEqual(run.text, "€8.99 / week")
    }
}
