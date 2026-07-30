import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// The paint side of the corpus, asserted as data.
///
/// The pixel goldens catch what this cannot — a shape drawn in the wrong order,
/// a stroke on the wrong side of its path — but they catch it as "these two
/// images differ", which names nothing. This names the node. Between the two,
/// the frames are checked against Chromium (`LayoutParityTests`) and the paint
/// is checked against the DOCUMENT, which is the only thing that can be checked
/// exactly: a fill is `#2E7D32` because the theme says `primary` is `#2E7D32`.
final class DisplayListTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    private var products: [String: [String: String]] {
        [
            "ai_interior_weekly": ["price": "€8.99", "period": "week"],
            "ai_interior_monthly": ["price": "€22.99", "period": "month"],
        ]
    }

    private func list(
        _ fixtureName: String, screen: Int, sel: [String: String] = [:]
    ) throws -> DisplayList {
        try ScreenRenderer().displayList(
            flow: try fixture(fixtureName),
            screenIndex: screen,
            input: LayoutInput(selections: sel, variables: sel, products: products),
            viewport: Viewport(size: Size2D(width: 390, height: 743), safeTop: 51)
        )
    }

    // MARK: - the palette

    /// A token becomes the theme's colour, not a guess.
    func testTokensResolveThroughTheFlowsTheme() throws {
        let paywall = try list("interior-paywall", screen: 0)
        // The CTA. `primary` is `#2E7D32` in this flow's tokens.
        let emerald = RGBA(r: 0x2E / 255, g: 0x7D / 255, b: 0x32 / 255)
        let filled = paywall.items.compactMap { item -> String? in
            guard case .flat(let c)? = item.style.fill, c == emerald else { return nil }
            return item.path
        }
        XCTAssertFalse(filled.isEmpty, "nothing picked up the theme's primary")
    }

    /// An unknown colour string must not become black.
    func testAnUnparseableColourIsAbsentRatherThanBlack() {
        XCTAssertNil(RGBA.parse("chartreuse-ish"))
        XCTAssertNil(RGBA.parse("#12345"))
        XCTAssertNil(RGBA.parse(nil))
        XCTAssertEqual(RGBA.parse("#FFF"), .white)
        XCTAssertEqual(RGBA.parse("#00000059")?.a ?? 0, 0x59 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(RGBA.parse("primary", tokens: ["primary": "#2E7D32"])?.g ?? 0,
                       0x7D / 255.0, accuracy: 0.0001)
    }

    // MARK: - order and clipping

    /// Paint order is tree order: a child covers its parent.
    func testAChildIsPaintedAfterItsParent() throws {
        let l = try list("wellness-onboarding", screen: 2)
        let parent = try XCTUnwrap(l.items.firstIndex { $0.path == "1.0" })
        let child = try XCTUnwrap(l.items.firstIndex { $0.path == "1.0.1" })
        XCTAssertLessThan(parent, child)
    }

    /// A node that clips puts its own rounded shape on its descendants.
    func testClippingDescends() throws {
        let l = try list("interior-paywall", screen: 0)
        let clippers = Set(l.items.filter { !$0.clips.isEmpty }.map(\.path))
        XCTAssertFalse(clippers.isEmpty, "the paywall's hero clips its photo")
        for item in l.items where !item.clips.isEmpty {
            // Every clip an item carries belongs to one of its own ancestors.
            for clip in item.clips {
                let owner = l.items.first { $0.shape == clip }
                let ownerPath = try XCTUnwrap(owner?.path, "a clip belongs to no item")
                XCTAssertTrue(
                    item.path.hasPrefix(ownerPath),
                    "\(item.path) is clipped by \(ownerPath), which is not an ancestor"
                )
            }
        }
    }

    /// Opacity multiplies down the tree.
    func testOpacityAccumulates() {
        var root = LayoutNode(path: "", type: "box")
        root.paint.opacity = 0.5
        var child = LayoutNode(path: "0", type: "box")
        child.paint.opacity = 0.5
        child.paint.fill = .flat(.black)
        root.children = [child]
        let frames = [
            SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 10, height: 10)),
            SolvedFrame(path: "0", rect: Rect(x: 0, y: 0, width: 10, height: 10)),
        ]
        let l = try? DisplayListBuilder.build(
            root: root, frames: frames, size: Size2D(width: 10, height: 10)
        )
        XCTAssertEqual(l?.item(at: "0")?.opacity ?? 0, 0.25, accuracy: 0.0001)
    }

    /// A node the solver dropped takes its subtree with it.
    ///
    /// An unmet condition removes a node from LAYOUT, so it has no frame; the
    /// display list must not resurrect it at the origin, which is what a
    /// zero-rect fallback would do.
    func testANodeWithNoFrameIsNotPainted() throws {
        var root = LayoutNode(path: "", type: "box")
        var ghost = LayoutNode(path: "0", type: "box")
        ghost.paint.fill = .flat(.black)
        ghost.children = [LayoutNode(path: "0.0", type: "box")]
        root.children = [ghost]
        let l = try DisplayListBuilder.build(
            root: root,
            frames: [SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 10, height: 10))],
            size: Size2D(width: 10, height: 10)
        )
        XCTAssertNil(l.item(at: "0"))
        XCTAssertNil(l.item(at: "0.0"))
    }

    // MARK: - shapes

    /// A `corner: 999` pill is clamped to a legal shape, proportionally.
    func testOversizedCornersAreFittedNotClamped() {
        let shape = RoundedRect(
            rect: Rect(x: 0, y: 0, width: 100, height: 40),
            corners: Corners(999)
        )
        // Half the short side, on every corner — a stadium.
        XCTAssertEqual(shape.corners.topLeft, 20, accuracy: 0.0001)
        XCTAssertEqual(shape.corners.bottomRight, 20, accuracy: 0.0001)

        // Proportional, not per-corner: an asymmetric set keeps its ratio.
        let lopsided = RoundedRect(
            rect: Rect(x: 0, y: 0, width: 60, height: 60),
            corners: Corners(topLeft: 40, topRight: 80, bottomRight: 0, bottomLeft: 0)
        )
        XCTAssertEqual(
            lopsided.corners.topRight / lopsided.corners.topLeft, 2, accuracy: 0.0001,
            "the 1:2 ratio should survive the fit"
        )
        XCTAssertLessThanOrEqual(lopsided.corners.topLeft + lopsided.corners.topRight, 60.0001)
    }

    // MARK: - refusals

    /// Four different border widths are refused rather than approximated.
    func testPerEdgeStrokeIsRefused() {
        var root = LayoutNode(path: "", type: "box")
        root.paint.stroke = Stroke(
            color: .black,
            width: Edges(top: 1, right: 2, bottom: 3, left: 4)
        )
        XCTAssertThrowsError(
            try DisplayListBuilder.build(
                root: root,
                frames: [SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 10, height: 10))],
                size: Size2D(width: 10, height: 10)
            )
        ) { error in
            XCTAssertEqual(error as? PaintUnsupported, .perEdgeStroke(path: ""))
        }
    }

    /// An OUTSIDE stroke paints past the bounds and must not narrow children.
    ///
    /// The solver takes an inside border out of the content box; doing that for
    /// an outside one would move every child in by the stroke width for a ring
    /// that is drawn beyond the box entirely.
    func testAnOutsideStrokeDoesNotEatTheContentBox() throws {
        let flow: [String: Any] = ["screens": [["root": [
            "type": "box",
            "style": ["stroke": ["color": "#000000", "width": 4, "align": "outside"]],
        ]]]]
        let tree = try XCTUnwrap(Decoder.layoutTree(flow: flow, screenIndex: 0))
        XCTAssertEqual(tree.borderWidth, 0)

        let inside: [String: Any] = ["screens": [["root": [
            "type": "box",
            "style": ["stroke": ["color": "#000000", "width": 4]],
        ]]]]
        let strict = try XCTUnwrap(Decoder.layoutTree(flow: inside, screenIndex: 0))
        XCTAssertEqual(strict.borderWidth, 4)
    }

    // MARK: - hit testing

    /// The topmost node wins, which is the last one painted.
    func testHitTestReturnsTheTopmostNode() throws {
        let l = try list("interior-paywall", screen: 0)
        let card = try XCTUnwrap(l.item(at: "1.3.0"), "the weekly card")
        let point = Point2D(
            x: card.frame.x + card.frame.width / 2,
            y: card.frame.y + card.frame.height / 2
        )
        let hit = try XCTUnwrap(l.hitTest(point))
        // Something inside the card, not the card's ancestors — a hit test that
        // walked forwards would return the root for every tap on the screen.
        XCTAssertTrue(
            hit.hasPrefix("1.3.0"),
            "tapping the weekly card's middle hit \(hit)"
        )
    }

    /// A point outside everything hits nothing.
    func testHitTestMissesOffScreen() throws {
        let l = try list("interior-paywall", screen: 0)
        XCTAssertNil(l.hitTest(Point2D(x: -5, y: 100)))
    }

    /// A node scrolled out of its clip is not hittable where its frame says.
    ///
    /// The frame is still the right answer for layout — it says where the node
    /// WOULD be — so a hit test that only checked frames would fire on taps
    /// landing on whatever is actually drawn there.
    func testHitTestRespectsClips() throws {
        var root = LayoutNode(path: "", type: "box")
        root.clipsContent = true
        root.paint.fill = .flat(.white)
        var child = LayoutNode(path: "0", type: "box")
        child.paint.fill = .flat(.black)
        root.children = [child]
        let l = try DisplayListBuilder.build(
            root: root,
            frames: [
                SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 100, height: 50)),
                // Hanging below the clip.
                SolvedFrame(path: "0", rect: Rect(x: 0, y: 60, width: 100, height: 40)),
            ],
            size: Size2D(width: 100, height: 100)
        )
        XCTAssertEqual(l.hitTest(Point2D(x: 50, y: 25)), "")
        XCTAssertNil(l.hitTest(Point2D(x: 50, y: 80)), "a clipped-away node was hit")
    }

    // MARK: - validation

    /// An untouched empty field is not invalid; a touched empty one is.
    ///
    /// The distinction is the entire difference between the `name-input` and
    /// `name-invalid` shots, and it is invisible to the frame baseline: the
    /// invalid delta changes the stroke's COLOUR and not its width, so every
    /// box stays exactly where it was. Only a paint test can see it, which is
    /// what these goldens are for — this state was silently missing until one
    /// of them rendered the two screens identically.
    func testTouchedAndEmptyRedensTheContainer() throws {
        let untouched = try list("wellness-onboarding", screen: 1)
        let touched = try list("wellness-onboarding", screen: 1, sel: ["first_name": ""])

        func strokeColour(_ l: DisplayList) -> RGBA? {
            l.items.compactMap { $0.style.stroke?.color }.first
        }
        let error = RGBA(r: 0xDC / 255, g: 0x26 / 255, b: 0x26 / 255)
        XCTAssertNotEqual(strokeColour(untouched), error, "an untouched field must not be red")
        XCTAssertEqual(strokeColour(touched), error, "a touched, empty field should redden")
    }

    // MARK: - the whole corpus

    /// Every shot builds, and every item lands inside the screen.
    ///
    /// Loose on purpose — it is a smoke test over all seven, where the specific
    /// assertions above are over one. A node at x = -9999 is the shape a decode
    /// bug takes, and it would otherwise only show up as a blank golden.
    func testEveryShotProducesADrawableList() throws {
        let shots: [(String, Int, [String: String])] = [
            ("interior-paywall", 0, [:]),
            ("interior-paywall", 0, ["plan": "monthly"]),
            ("wellness-onboarding", 0, [:]),
            ("wellness-onboarding", 1, [:]),
            ("wellness-onboarding", 2, [:]),
            ("wellness-onboarding", 2, ["focus": "sleep", "first_name": "Alex"]),
        ]
        for (name, screen, sel) in shots {
            let l = try list(name, screen: screen, sel: sel)
            XCTAssertGreaterThan(l.drawable.count, 3, "\(name)#\(screen) drew almost nothing")
            for item in l.drawable {
                XCTAssertGreaterThan(item.frame.width, 0, "\(item.path) has no width")
                XCTAssertLessThan(item.frame.x, 390, "\(item.path) starts off-screen")
                XCTAssertGreaterThan(item.frame.x + item.frame.width, 0, "\(item.path) ends off-screen")
            }
        }
    }
}
