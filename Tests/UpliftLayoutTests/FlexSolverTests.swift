import XCTest
@testable import UpliftLayout

/// The solver, against the CSS rules it exists to reproduce.
///
/// Every case here is a rule `render/css.ts` implements, several of them
/// recorded there as bug fixes with the symptom written down. They are asserted
/// on numbers a browser would produce, so a divergence shows up as arithmetic
/// rather than as a screenshot nobody can read.
final class FlexSolverTests: XCTestCase {
    /// Text measured as a fixed advance per character, so a box test never
    /// depends on a shaper. The real one is asserted separately.
    struct Ruler: TextMeasuring {
        let advance: Double
        let lineHeight: Double
        func measure(_ run: TextRunSpec) -> TextMetrics {
            let full = Double(run.text.count) * advance
            guard let max = run.maxWidth, max > 0, full > max else {
                return TextMetrics(
                    lines: [TextLine(text: run.text, width: full)], width: full, height: lineHeight
                )
            }
            let perLine = Swift.max(1, Int(max / advance))
            let lineCount = Int((Double(run.text.count) / Double(perLine)).rounded(.up))
            return TextMetrics(
                lines: (0..<lineCount).map { _ in TextLine(text: "", width: max) },
                width: max,
                height: lineHeight * Double(lineCount)
            )
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { advance }
    }

    private func solver() -> FlexSolver {
        FlexSolver(measurer: Ruler(advance: 10, lineHeight: 20))
    }
    private let viewport = Viewport(size: Size2D(width: 390, height: 743), safeTop: 51)

    private func node(
        _ path: String, _ type: String = "box", _ build: (inout LayoutNode) -> Void = { _ in }
    ) -> LayoutNode {
        var n = LayoutNode(path: path, type: type)
        build(&n)
        return n
    }

    private func frames(_ root: LayoutNode) throws -> [String: Rect] {
        var out: [String: Rect] = [:]
        for f in try solver().solve(root: root, viewport: viewport) { out[f.path] = f.rect }
        return out
    }

    // MARK: - grow

    /// The traced case: a row 342 wide, gap 12, children {grow:1, 72, grow:1}.
    /// CSS gives 123 / 72 / 123, because a grow child's BASE is zero and the
    /// free space is shared by weight — not added on top of its content size.
    func testGrowSharesFreeSpaceFromAZeroBase() throws {
        let root = node("", "box") { n in
            n.mode = .row
            n.gapMain = 12
            n.width = .points(342)
            n.height = .points(100)
            n.children = [
                node("0") { $0.grow = 1 },
                node("1") { $0.width = .points(72) },
                node("2") { $0.grow = 1 },
            ]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.width, 123)
        XCTAssertEqual(f["1"]!.width, 72)
        XCTAssertEqual(f["2"]!.width, 123)
        XCTAssertEqual(f["0"]!.x, 0)
        XCTAssertEqual(f["1"]!.x, 135)
        XCTAssertEqual(f["2"]!.x, 219)
    }

    /// `width: "fill"` on the main axis IS `flex-grow: 1` — css.ts sets it when
    /// no explicit `grow` is given.
    func testFillOnTheMainAxisGrows() throws {
        let root = node("") { n in
            n.mode = .row
            n.width = .points(300)
            n.height = .points(50)
            n.children = [node("0") { $0.width = .fill }, node("1") { $0.width = .points(100) }]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.width, 200)
        XCTAssertEqual(f["1"]!.width, 100)
    }

    /// An over-subscribed row does NOT squash its fixed children. css.ts sets
    /// `flexShrink: 0` on any explicit main-axis size — recorded there against
    /// a 300pt hero that a scrolling column was collapsing. The parent
    /// overflows; the scroll is the answer.
    func testAnExplicitMainSizeIsNeverShrunk() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .points(200)
            n.children = [
                node("0") { $0.height = .points(300) },
                node("1") { $0.height = .points(100) },
            ]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.height, 300, "the hero keeps its height and the parent overflows")
        XCTAssertEqual(f["1"]!.height, 100)
        XCTAssertEqual(f["1"]!.y, 300)
    }

    // MARK: - cross axis

    /// `align-items: stretch` is CSS's default and css.ts emits it whenever the
    /// author said nothing, which is why a column's children are as wide as the
    /// column without asking for it.
    func testTheCrossAxisStretchesByDefault() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .points(400)
            n.children = [node("0") { $0.height = .points(50) }]
        }
        XCTAssertEqual(try frames(root)["0"]!.width, 390)
    }

    /// …but an explicit cross size defeats the stretch.
    func testAnExplicitCrossSizeWins() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .points(400)
            n.children = [node("0") { $0.width = .points(120); $0.height = .points(50) }]
        }
        XCTAssertEqual(try frames(root)["0"]!.width, 120)
    }

    func testCrossAlignmentCentres() throws {
        let root = node("") { n in
            n.mode = .column
            n.alignX = .center
            n.width = .points(390)
            n.height = .points(400)
            n.children = [node("0") { $0.width = .points(100); $0.height = .points(50) }]
        }
        XCTAssertEqual(try frames(root)["0"]!.x, 145)
    }

    // MARK: - padding and gap

    func testPaddingInsetsTheContentBoxAndGapSeparates() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .points(400)
            n.padding = Edges(top: 24, right: 20, bottom: 24, left: 20)
            n.gapMain = 12
            n.children = [
                node("0") { $0.height = .points(40) },
                node("1") { $0.height = .points(40) },
            ]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.x, 20)
        XCTAssertEqual(f["0"]!.y, 24)
        XCTAssertEqual(f["0"]!.width, 350, "content box is the padding box minus the padding")
        XCTAssertEqual(f["1"]!.y, 76, "40 tall, then the 12 gap")
    }

    // MARK: - hug

    func testHugWrapsItsChildren() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .hug
            n.padding = Edges(top: 10, right: 0, bottom: 10, left: 0)
            n.gapMain = 6
            n.children = [
                node("0") { $0.height = .points(30) },
                node("1") { $0.height = .points(20) },
            ]
        }
        XCTAssertEqual(try frames(root)[""]!.height, 76, "10 + 30 + 6 + 20 + 10")
    }

    // MARK: - out of flow

    func testAbsoluteResolvesAgainstItsContainerAndLeavesTheFlow() throws {
        let root = node("") { n in
            n.mode = .column
            n.width = .points(390)
            n.height = .points(400)
            n.children = [
                node("0") { c in
                    c.position = .absolute
                    c.inset = Edges(top: 12, right: 0, bottom: 0, left: 16)
                    c.insetSides = (top: true, right: false, bottom: false, left: true)
                    c.width = .points(32); c.height = .points(32)
                },
                node("1") { $0.height = .points(50) },
            ]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.x, 16)
        XCTAssertEqual(f["0"]!.y, 12)
        XCTAssertEqual(f["1"]!.y, 0, "the absolute sibling took no room in the flow")
    }

    /// A negative inset is how the paywall's badge overhangs its card.
    func testANegativeInsetOverhangs() throws {
        let root = node("") { n in
            n.width = .points(390); n.height = .points(400)
            n.children = [node("0") { c in
                c.position = .absolute
                c.inset = Edges(top: -10, right: 0, bottom: 0, left: -8)
                c.insetSides = (top: true, right: false, bottom: false, left: true)
                c.width = .points(40); c.height = .points(20)
            }]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.x, -8)
        XCTAssertEqual(f["0"]!.y, -10)
    }

    func testOppositeInsetsPinBothEdgesAndSizeTheNode() throws {
        let root = node("") { n in
            n.width = .points(390); n.height = .points(400)
            n.children = [node("0") { c in
                c.position = .absolute
                c.inset = Edges(top: 0, right: 20, bottom: 0, left: 20)
                c.insetSides = (top: false, right: true, bottom: false, left: true)
            }]
        }
        XCTAssertEqual(try frames(root)["0"]!.width, 350)
    }

    /// `fixed` pins to the screen rather than to the parent — the pinned footer.
    func testFixedResolvesAgainstTheViewport() throws {
        let root = node("") { n in
            n.mode = .column
            n.padding = Edges(top: 40, right: 20, bottom: 40, left: 20)
            n.width = .points(390); n.height = .points(400)
            n.children = [node("0") { c in
                c.position = .fixed
                c.inset = Edges(top: 0, right: 0, bottom: 0, left: 0)
                c.insetSides = (top: false, right: false, bottom: true, left: false)
                c.height = .points(60)
            }]
        }
        let f = try frames(root)
        XCTAssertEqual(f["0"]!.y, 683, "743 viewport minus its own 60, ignoring the parent's padding")
    }

    // MARK: - refusals

    /// A solver that quietly treated `grid` as a column would give a plausible
    /// wrong answer, and a plausible wrong answer in a layout engine ships.
    func testUnsupportedModesRefuseRatherThanGuess() {
        let root = node("") { n in
            n.mode = .grid
            n.width = .points(390); n.height = .points(400)
            n.children = [node("0")]
        }
        XCTAssertThrowsError(try frames(root)) { err in
            XCTAssertEqual(err as? LayoutUnsupported, .mode(.grid, path: ""))
        }
    }

    func testPercentSizesRefuse() {
        let root = node("") { n in
            n.width = .points(390); n.height = .points(400)
            n.children = [node("0") { $0.width = .percent(50) }]
        }
        XCTAssertThrowsError(try frames(root)) { err in
            XCTAssertEqual(err as? LayoutUnsupported, .percentSize(path: "0"))
        }
    }

    // MARK: - quantisation

    func testEveryFrameLandsOnTheLayoutGrid() throws {
        let root = node("") { n in
            n.mode = .row
            n.width = .points(100); n.height = .points(50)
            n.children = [node("0") { $0.grow = 1 }, node("1") { $0.grow = 1 }, node("2") { $0.grow = 1 }]
        }
        // 100 / 3 is not representable; each frame must sit on a sixty-fourth.
        for (_, r) in try frames(root) {
            XCTAssertEqual(r.x, lu(r.x))
            XCTAssertEqual(r.width, lu(r.width))
        }
        XCTAssertEqual(try frames(root)["0"]!.width, 33.328125)
    }
}
