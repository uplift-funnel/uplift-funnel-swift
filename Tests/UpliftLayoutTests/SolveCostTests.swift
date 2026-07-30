import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// What one solve costs, held to a number.
///
/// A ratchet in the same idiom as the frame floors: the parity suites prove the
/// solver gets the RIGHT answer, and this proves it stops asking the same
/// question over and over to get there. Without it the memo is one refactor
/// away from being silently removed, and nothing would fail — the frames would
/// still be exact, just slowly.
///
/// The numbers here are measured, not chosen. Before the memo the paywall took
/// 1,930 measurements for its nineteen distinct strings, because a row measures
/// its children once for the flex base, again for the cross size, and again
/// when placing them — and every one of those recursed into a whole subtree.
final class SolveCostTests: XCTestCase {
    /// Counts what the solver asks the shaper for, and answers from a fixed
    /// table so the count is the only variable.
    private final class Counting: TextMeasuring, @unchecked Sendable {
        private let inner: any TextMeasuring
        private(set) var measures = 0
        init(_ inner: any TextMeasuring) { self.inner = inner }
        func measure(_ run: TextRunSpec) -> TextMetrics {
            measures += 1
            return inner.measure(run)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { inner.minContentWidth(run) }
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func solveCost(_ fixtureName: String, screen: Int) throws -> Int {
        let flow = try fixture(fixtureName)
        let input = LayoutInput(products: [
            "ai_interior_weekly": ["price": "€8.99", "period": "week"],
            "ai_interior_monthly": ["price": "€22.99", "period": "month"],
        ])
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: flow, screenIndex: screen, input: input)
        )
        let counter = Counting(CoreTextMeasurer())
        _ = try FlexSolver(measurer: counter).solve(
            root: tree,
            viewport: Viewport(size: Size2D(width: 390, height: 743), safeTop: 51)
        )
        return counter.measures
    }

    /// Lower these as the solver improves; never raise one to make a run green.
    func testTheSolverDoesNotReMeasureTheWholeScreen() throws {
        let paywall = try solveCost("interior-paywall", screen: 0)
        let focus = try solveCost("wellness-onboarding", screen: 2)
        print("SOLVE COST  paywall \(paywall) measures, focus \(focus)")

        // 1,930 before the memo; 388 after. The ceiling leaves room for a
        // fixture to grow a node without a false failure, and none for the
        // hundredfold blow-up coming back.
        XCTAssertLessThan(paywall, 500, "the paywall solve is re-measuring: \(paywall)")
        XCTAssertLessThan(focus, 250, "the focus solve is re-measuring: \(focus)")
    }

    /// The memo must not survive a solve.
    ///
    /// The bug it would cause is invisible in a single render and obvious in a
    /// session: an answer changes a state delta, the delta changes what a node
    /// measures to, and a memo keyed by path would hand back the old size. So
    /// solving the SAME tree twice through one solver must cost the same twice
    /// — a cheaper second run would mean state leaked across the boundary.
    func testTheMemoDoesNotOutliveOneSolve() throws {
        let flow = try fixture("wellness-onboarding")
        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(flow: flow, screenIndex: 2))
        let viewport = Viewport(size: Size2D(width: 390, height: 743), safeTop: 51)
        let counter = Counting(CoreTextMeasurer())
        let solver = FlexSolver(measurer: counter)

        _ = try solver.solve(root: tree, viewport: viewport)
        let first = counter.measures
        _ = try solver.solve(root: tree, viewport: viewport)
        let second = counter.measures - first

        XCTAssertEqual(
            second, first,
            "the second solve cost \(second) where the first cost \(first) — "
            + "the memo outlived its pass, and a changed answer would read stale"
        )
    }
}
