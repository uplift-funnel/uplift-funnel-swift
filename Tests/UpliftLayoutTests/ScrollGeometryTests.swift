import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// What scrolls, and how far.
final class ScrollGeometryTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func solve(_ name: String, screen: Int) throws -> (LayoutNode, [SolvedFrame]) {
        let input = LayoutInput(products: [
            "ai_interior_weekly": ["price": "€8.99", "period": "week"],
            "ai_interior_monthly": ["price": "€22.99", "period": "month"],
        ])
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: try fixture(name), screenIndex: screen, input: input)
        )
        let frames = try FlexSolver(measurer: CoreTextMeasurer()).solve(
            root: tree, viewport: Viewport(size: Size2D(width: 390, height: 743), safeTop: 51)
        )
        return (tree, frames)
    }

    /// The number this whole phase exists for.
    ///
    /// The paywall is 174pt taller than the screen it sits on. Before this that
    /// overflow — the CTA included — was clipped away and untappable, on a
    /// document whose root says `scroll: "vertical"`.
    func testThePaywallScrolls() throws {
        let (tree, frames) = try solve("interior-paywall", screen: 0)
        let scrollers = ScrollGeometry.scrollers(root: tree, frames: frames)
        let root = try XCTUnwrap(scrollers.first { $0.path == "" }, "the root declares scroll")

        XCTAssertEqual(root.axis, .vertical)
        XCTAssertEqual(root.viewport.height, 743, accuracy: 0.001)
        XCTAssertTrue(root.scrolls)
        XCTAssertEqual(root.overflow, 173.953125, accuracy: 0.01)
    }

    /// A screen that fits does not scroll, and must not report that it does —
    /// a scroll view over content shorter than itself bounces for no reason.
    func testAShortScreenDoesNotScroll() throws {
        let (tree, frames) = try solve("wellness-onboarding", screen: 0)
        for scroller in ScrollGeometry.scrollers(root: tree, frames: frames) {
            XCTAssertFalse(
                scroller.scrolls,
                "\(scroller.path) reports \(scroller.overflow)pt of overflow on a screen that fits"
            )
        }
    }

    /// Overflow before the start edge is unreachable, exactly as in CSS.
    ///
    /// The paywall's hero carries `ignoreSafeArea` and sits at y = -51. You
    /// cannot scroll up past the top of a document, so that 51pt stays clipped
    /// — which is also what the browser recorded and what the paint goldens
    /// already show.
    func testContentDoesNotExtendAboveTheStart() throws {
        let (tree, frames) = try solve("interior-paywall", screen: 0)
        let root = try XCTUnwrap(
            ScrollGeometry.scrollers(root: tree, frames: frames).first { $0.path == "" }
        )
        XCTAssertEqual(root.content.y, 0, accuracy: 0.001)
        let hero = try XCTUnwrap(frames.first { $0.path == "0" })
        XCTAssertLessThan(hero.rect.y, 0, "the fixture's hero should still bleed upward")
    }

    /// A clipping box keeps its own overflow to itself.
    func testAClippingBoxDoesNotExtendTheScroller() {
        var root = LayoutNode(path: "", type: "box")
        root.scroll = .vertical
        var card = LayoutNode(path: "0", type: "box")
        card.clipsContent = true
        card.children = [LayoutNode(path: "0.0", type: "image")]
        root.children = [card]

        let frames = [
            SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 390, height: 700)),
            SolvedFrame(path: "0", rect: Rect(x: 0, y: 0, width: 390, height: 200)),
            // A photo overflowing the card that clips it.
            SolvedFrame(path: "0.0", rect: Rect(x: 0, y: 0, width: 390, height: 5000)),
        ]
        let root2 = ScrollGeometry.scrollers(root: root, frames: frames)[0]
        XCTAssertFalse(
            root2.scrolls,
            "a clipped photo made the screen scrollable: \(root2.content.height)"
        )
    }

    /// A fixed footer pins to the screen; it neither scrolls nor lengthens.
    func testAFixedNodeDoesNotExtendTheScroller() {
        var root = LayoutNode(path: "", type: "box")
        root.scroll = .vertical
        var footer = LayoutNode(path: "0", type: "box")
        footer.position = .fixed
        root.children = [footer]

        let frames = [
            SolvedFrame(path: "", rect: Rect(x: 0, y: 0, width: 390, height: 700)),
            SolvedFrame(path: "0", rect: Rect(x: 0, y: 640, width: 390, height: 60)),
        ]
        XCTAssertFalse(ScrollGeometry.scrollers(root: root, frames: frames)[0].scrolls)
    }
}
