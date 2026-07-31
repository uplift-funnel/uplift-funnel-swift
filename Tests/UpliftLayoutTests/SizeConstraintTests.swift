import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// The properties the acceptance corpus never uses.
///
/// `minWidth`, `maxWidth`, `aspect` and friends were in the schema and emitted
/// by the web renderer from the day v3 shipped, and neither solver read a
/// single one of them. Nothing failed, because neither fixture sets them — an
/// ignored property is indistinguishable from a property nobody wrote.
///
/// So a document using them laid out one way in the preview and another on the
/// device, silently. `aspect` is the sharpest case: the editor's own image
/// factory puts `aspect: 1.5` on every image an author adds, which means the
/// most common node in the product was shipping a wrong height.
///
/// Synthetic, because there is no other way to reach them.
final class SizeConstraintTests: XCTestCase {
    private struct Ruler: TextMeasuring {
        func measure(_ run: TextRunSpec) -> TextMetrics {
            TextMetrics(lines: [TextLine(text: run.text, width: 10)], width: 10, height: 20)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { 10 }
    }

    private func frames(_ root: [String: Any], width: Double = 390) throws -> [String: Rect] {
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: ["screens": [["root": root]]], screenIndex: 0)
        )
        let solved = try FlexSolver(measurer: Ruler()).solve(
            root: tree,
            viewport: Viewport(size: Size2D(width: width, height: 800), safeTop: 0)
        )
        return Dictionary(solved.map { ($0.path, $0.rect) }) { a, _ in a }
    }

    // MARK: - min / max

    func testMaxWidthCapsAFillingChild() throws {
        let f = try frames([
            "type": "box",
            "children": [["type": "box", "self": ["width": "fill", "maxWidth": 200, "height": 40]]],
        ])
        XCTAssertEqual(f["0"]?.width, 200, "maxWidth did not cap a fill child")
    }

    /// A min RAISES; it never caps.
    ///
    /// The parent aligns rather than stretches, because a stretched child fills
    /// its container and `min-width: 120` in a 390pt column leaves it at 390 —
    /// which is CSS, and which this test asserted the opposite of on the first
    /// try. Worth keeping the reason written down: the interesting case is a
    /// child that would otherwise be NARROWER than its floor.
    func testMinWidthRaisesAChildThatDoesNotStretch() throws {
        let f = try frames([
            "type": "box",
            "layout": ["alignX": "start"],
            "children": [["type": "box", "self": ["minWidth": 120, "height": 40]]],
        ])
        XCTAssertEqual(f["0"]?.width, 120, "minWidth did not raise an empty box")
    }

    /// CSS resolves `max` first and then `min`, so a min larger than the max
    /// WINS. Backwards-looking and deliberate: the floor is a promise that the
    /// content fits, where the ceiling is only a preference.
    func testMinBeatsMaxWhenTheyConflict() throws {
        let f = try frames([
            "type": "box",
            "children": [[
                "type": "box",
                "self": ["width": "fill", "minWidth": 300, "maxWidth": 100, "height": 40],
            ]],
        ])
        XCTAssertEqual(f["0"]?.width, 300)
    }

    func testMaxHeightCapsAColumn() throws {
        let f = try frames([
            "type": "box",
            "children": [[
                "type": "box",
                "self": ["maxHeight": 50],
                "layout": ["mode": "column"],
                "children": [
                    ["type": "box", "self": ["height": 40]],
                    ["type": "box", "self": ["height": 40]],
                ],
            ]],
        ])
        XCTAssertEqual(f["0"]?.height, 50, "maxHeight did not cap a hugging column")
    }

    // MARK: - aspect

    /// `aspect-ratio: N` is width ÷ height, so a 1.5 image 300 wide is 200 tall.
    func testAspectDerivesHeightFromWidth() throws {
        let f = try frames([
            "type": "box",
            "children": [["type": "image", "self": ["width": 300, "aspect": 1.5]]],
        ])
        XCTAssertEqual(f["0"]?.height ?? 0, 200, accuracy: 0.02)
    }

    /// The editor's own default, at the width it really gets.
    func testTheEditorsDefaultImageGetsAHeight() throws {
        let f = try frames([
            "type": "box",
            "layout": ["padding": [0, 20, 0, 20]],
            "children": [["type": "image", "self": ["width": "fill", "aspect": 1.5]]],
        ])
        // 390 - 40 of padding = 350 wide, so 350 / 1.5.
        XCTAssertEqual(f["0"]?.width ?? 0, 350, accuracy: 0.02)
        XCTAssertEqual(f["0"]?.height ?? 0, 350 / 1.5, accuracy: 0.02)
        XCTAssertGreaterThan(f["0"]?.height ?? 0, 0, "an aspect image with no children had no height")
    }

    /// An explicit height wins: `aspect` derives what is NOT given.
    func testAnExplicitHeightBeatsAspect() throws {
        let f = try frames([
            "type": "box",
            "children": [["type": "image", "self": ["width": 300, "height": 90, "aspect": 1.5]]],
        ])
        XCTAssertEqual(f["0"]?.height, 90)
    }

    /// A ratio and a ceiling together must still describe the same shape.
    func testAspectAndMaxHeightStayInRatio() throws {
        let f = try frames([
            "type": "box",
            "children": [["type": "box", "self": ["aspect": 2, "minWidth": 400, "maxHeight": 50]]],
        ])
        let box = try XCTUnwrap(f["0"])
        XCTAssertEqual(box.height, 50, "maxHeight was ignored")
        XCTAssertEqual(box.width, 400, "minWidth was ignored")
    }

    // MARK: - margin and distribute

    /// Margin is outside the border box: it pushes siblings, and it eats the
    /// room the children then have less of.
    func testMarginPushesSiblingsAndCostsRoom() throws {
        let f = try frames([
            "type": "box",
            "layout": ["mode": "row"],
            "children": [
                ["type": "box", "self": ["width": 100, "height": 40, "margin": [0, 20, 0, 0]]],
                ["type": "box", "self": ["width": "fill", "height": 40]],
            ],
        ])
        // First child at 0..100, then 20 of margin, so the filler starts at 120
        // and gets what is left of 390.
        XCTAssertEqual(f["1"]?.x, 120, "the trailing margin did not push the sibling")
        XCTAssertEqual(f["1"]?.width, 270, "the margin did not cost the filler its room")
    }

    /// A stretched child is sized against the room its margins leave.
    ///
    /// The case the corpus could not speak for and the main-axis cases above
    /// did not reach: `margin` on the CROSS axis. `align-items: stretch` hands
    /// over the container's cross size minus the child's own margins, so a
    /// NEGATIVE margin makes the child bigger — which is the whole mechanism by
    /// which a full-bleed hero escapes its parent's padding.
    ///
    /// Numbers measured in Chromium, not derived: a 390pt column padded 24 each
    /// side stretches a `margin: 0 -24px` child to x = 0, w = 390.
    func testANegativeCrossMarginWidensAStretchedChild() throws {
        let f = try frames([
            "type": "box",
            "layout": ["alignX": "stretch", "padding": [0, 24, 24, 24]],
            "children": [
                ["type": "box", "self": ["height": 220, "margin": [0, -24, 0, -24]]],
                ["type": "box", "self": ["height": 40]],
            ],
        ])
        XCTAssertEqual(f["0"]?.x, 0, "the bleeding child should start at the left edge")
        XCTAssertEqual(f["0"]?.width, 390, "the negative cross margin did not widen the child")
        // Its sibling is untouched: a margin is one child's business.
        XCTAssertEqual(f["1"]?.x, 24)
        XCTAssertEqual(f["1"]?.width, 342)
    }

    /// The same rule in the other direction — Chromium: x = 34, w = 322.
    func testAPositiveCrossMarginNarrowsAStretchedChild() throws {
        let f = try frames([
            "type": "box",
            "layout": ["alignX": "stretch", "padding": [0, 24, 0, 24]],
            "children": [["type": "box", "self": ["height": 30, "margin": [0, 10, 0, 10]]]],
        ])
        XCTAssertEqual(f["0"]?.x, 34)
        XCTAssertEqual(f["0"]?.width, 322)
    }

    /// An alignment shares out the space left AFTER the margins.
    ///
    /// Chromium centres a 100pt box carrying a 40pt right margin in a 342pt
    /// content box at x = 125 — (342 − 40 − 100) / 2 + 24 — not at 145.
    func testACrossMarginShiftsWhatAnAlignmentCentres() throws {
        let f = try frames([
            "type": "box",
            "layout": ["alignX": "center", "padding": [0, 24, 0, 24]],
            "children": [
                ["type": "box", "self": ["width": 100, "height": 30, "margin": [0, 40, 0, 0]]],
            ],
        ])
        XCTAssertEqual(f["0"]?.x, 125)
        XCTAssertEqual(f["0"]?.width, 100)
    }

    /// A row's cross axis is the vertical one, and it obeys the same rule —
    /// Chromium: y = 346, h = 96 for `margin: -8px 0` in a 100pt row padded 10.
    func testACrossMarginOnARowIsVertical() throws {
        let f = try frames([
            "type": "box",
            "self": ["height": 100],
            "layout": ["mode": "row", "alignY": "stretch", "padding": [10, 10, 10, 10]],
            "children": [["type": "box", "self": ["width": 50, "margin": [-8, 0, -8, 0]]]],
        ])
        XCTAssertEqual(f["0"]?.y, 2, "y = 10 of padding − 8 of margin")
        XCTAssertEqual(f["0"]?.height, 96, "the negative cross margin did not heighten the child")
    }

    /// `distribute: between` puts the leftover BETWEEN the children — outer
    /// edges flush, which is what `justify-content: space-between` does.
    func testDistributeBetweenSpreadsTheLeftover() throws {
        let f = try frames([
            "type": "box",
            "layout": ["mode": "row", "distribute": "between"],
            "children": [
                ["type": "box", "self": ["width": 100, "height": 40]],
                ["type": "box", "self": ["width": 100, "height": 40]],
            ],
        ])
        XCTAssertEqual(f["0"]?.x, 0, "the first child should stay flush")
        XCTAssertEqual(f["1"]?.x, 290, "the last child should end flush at 390")
    }

    /// `evenly` gives equal space at both ends and between.
    func testDistributeEvenly() throws {
        let f = try frames([
            "type": "box",
            "layout": ["mode": "row", "distribute": "evenly"],
            "children": [
                ["type": "box", "self": ["width": 90, "height": 40]],
                ["type": "box", "self": ["width": 90, "height": 40]],
            ],
        ])
        // 390 - 180 = 210 over three equal gaps.
        XCTAssertEqual(f["0"]?.x ?? 0, 70, accuracy: 0.02)
        XCTAssertEqual(f["1"]?.x ?? 0, 230, accuracy: 0.02)
    }

    /// Packed is still the default, and still respects the alignment.
    func testPackedStillCentresWithAlignX() throws {
        let f = try frames([
            "type": "box",
            "layout": ["mode": "row", "alignX": "center"],
            "children": [["type": "box", "self": ["width": 100, "height": 40]]],
        ])
        XCTAssertEqual(f["0"]?.x ?? 0, 145, accuracy: 0.02)
    }
}
