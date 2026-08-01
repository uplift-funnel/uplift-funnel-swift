import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// The four things the editor was getting wrong that this engine was getting
/// wrong too, in exactly the same places.
///
/// They were found in the dashboard — a screen whose sign-in stack drew over
/// the button below it, a plan card whose title wrapped one letter per line, a
/// badge that wrapped inside a pill sized for the un-uppercased label, and a
/// progress bar that never moved. All four are decisions this port had copied,
/// so all four shipped on device as well; the acceptance corpus never caught
/// them because no fixture uses a native leaf, a `minWidth` or a `transform`.
final class NativeLeafAndStepTests: XCTestCase {
    private struct Ruler: TextMeasuring {
        /// Wide enough that a growing column would wrap if it were not clamped:
        /// each character is 10pt and nothing breaks.
        func measure(_ run: TextRunSpec) -> TextMetrics {
            let w = Double(run.text.count) * 10
            return TextMetrics(lines: [TextLine(text: run.text, width: w)], width: w, height: 20)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { Double(run.text.count) * 10 }
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

    // MARK: - native leaves occupy space

    func testSignInStackIsAsTallAsItsButtons() throws {
        let f = try frames([
            "type": "box",
            "children": [[
                "type": "signin",
                "bind": ["save_to": "account"],
                "props": ["providers": [["provider": "apple"], ["provider": "google"]]],
            ]],
        ])
        // Two buttons and the 10pt between them: 14pt of padding around a
        // 16pt label at 1.2 line height, quantised to the 1/64 grid — the same
        // 47.1875 decode.ts computes, which is what parity means here.
        XCTAssertEqual(f["0"]?.height ?? 0, 2 * 47.1875 + 10, accuracy: 0.001)
    }

    func testPermissionRowIsNotZeroHigh() throws {
        let f = try frames([
            "type": "box",
            "children": [[
                "type": "permission",
                "bind": ["save_to": "reminders"],
                "props": ["permission": "notifications"],
            ]],
        ])
        XCTAssertGreaterThan(f["0"]?.height ?? 0, 30)
    }

    func testARectangularPhotoFrameClaimsTheWidthAndIsThreeByTwo() throws {
        let f = try frames([
            "type": "box",
            "children": [["type": "photo_upload", "bind": ["save_to": "selfie"]]],
        ])
        let frame = try XCTUnwrap(f["0"])
        XCTAssertEqual(frame.width, 390, accuracy: 0.01)
        XCTAssertEqual(frame.height, 260, accuracy: 0.01)
    }

    func testACircularPhotoFrameIsADisc() throws {
        let f = try frames([
            "type": "box",
            "children": [[
                "type": "photo_upload",
                "bind": ["save_to": "avatar"],
                "props": ["shape": "circle"],
            ]],
        ])
        let frame = try XCTUnwrap(f["0"])
        XCTAssertEqual(frame.width, 144, accuracy: 0.01)
        XCTAssertEqual(frame.height, 144, accuracy: 0.01)
    }

    func testASealedLeafNoLongerCollapsesOntoItsNeighbour() throws {
        let f = try frames([
            "type": "box",
            "layout": ["mode": "column"],
            "children": [
                ["type": "permission", "bind": ["save_to": "r"], "props": ["permission": "camera"]],
                ["type": "text", "props": ["value": "after"]],
            ],
        ])
        let leaf = try XCTUnwrap(f["0"])
        let after = try XCTUnwrap(f["1"])
        XCTAssertGreaterThanOrEqual(after.y, leaf.y + leaf.height)
    }

    // MARK: - a growing child has a floor

    func testAGrowingColumnIsClampedToItsMinWidth() throws {
        // The plan-card row: a title column that grows beside a price that
        // cannot break. Without a floor the column takes what is left — here
        // nothing — and its text wraps a letter at a time.
        let f = try frames([
            "type": "box",
            "layout": ["mode": "row", "gap": 12],
            "children": [
                [
                    "type": "box",
                    "self": ["grow": 1, "minWidth": 130],
                    "children": [["type": "text", "props": ["value": "Yearly"]]],
                ],
                ["type": "text", "props": ["value": "$59.99 / year and then some"]],
            ],
        ], width: 200)
        XCTAssertGreaterThanOrEqual(f["0"]?.width ?? 0, 130)
    }

    // MARK: - case is applied before measuring

    func testAnUppercasedLabelMeasuresAtItsPaintedWidth() throws {
        let plain = try frames([
            "type": "box",
            "children": [["type": "text", "props": ["value": "Best value"]]],
        ])
        let upper = try frames([
            "type": "box",
            "children": [[
                "type": "text",
                "props": ["value": "Best value"],
                "style": ["text": ["transform": "uppercase"]],
            ]],
        ])
        // The ruler is case-blind, so identical widths prove the decoder passed
        // the transformed string down: what changes is the run's own text.
        XCTAssertEqual(plain["0"]?.width, upper["0"]?.width)

        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: ["screens": [["root": [
                "type": "box",
                "children": [[
                    "type": "text",
                    "props": ["value": "Best value"],
                    "style": ["text": ["transform": "uppercase"]],
                ]],
            ]]]], screenIndex: 0)
        )
        XCTAssertEqual(tree.children.first?.text?.text, "BEST VALUE")
    }

    // MARK: - the screen's background reaches the top of the display

    private func list(_ root: [String: Any]) throws -> DisplayList {
        try XCTUnwrap(
            try ScreenRenderer(measurer: Ruler()).displayList(
                flow: ["screens": [["root": root]]],
                screenIndex: 0,
                viewport: Viewport(size: Size2D(width: 390, height: 800), safeTop: 0)
            )
        )
    }

    func testTheRootFillIsHoistedOffTheTreeSoItCanBeDrawnFullBleed() throws {
        let (background, stripped) = try list([
            "type": "box",
            "style": ["fill": "#101828", "corner": 12],
            "children": [["type": "text", "props": ["value": "hi"]]],
        ]).hoistingRootFill()

        XCTAssertNotNil(background?.fill)
        // What stays behind keeps the rest of the root's paint and none of the
        // fill — drawing it twice at two heights seams a gradient.
        XCTAssertNil(stripped.item(at: "")?.style.fill)
        XCTAssertEqual(stripped.item(at: "")?.style.corners, background?.corners)
    }

    func testAScreenWithNoRootFillHoistsNothing() throws {
        let (background, stripped) = try list([
            "type": "box",
            "children": [["type": "text", "props": ["value": "hi"]]],
        ]).hoistingRootFill()
        XCTAssertNil(background)
        XCTAssertEqual(stripped.items.count, 2)
    }

    func testABleedingHeroRisesByTheWholeBandAboveTheBody() throws {
        // The host passes the status bar AND the chrome row as `safeTop`, so a
        // hero carrying `ignoreSafeArea` reaches the top of the DISPLAY rather
        // than stopping a chrome row short of it.
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: ["screens": [["root": [
                "type": "box",
                "children": [[
                    "type": "box",
                    "self": ["width": "fill", "height": 200, "ignoreSafeArea": true],
                ]],
            ]]]], screenIndex: 0)
        )
        let solved = try FlexSolver(measurer: Ruler()).solve(
            root: tree,
            viewport: Viewport(size: Size2D(width: 390, height: 700), safeTop: 51 + 44)
        )
        let hero = try XCTUnwrap(solved.first { $0.path == "0" })
        XCTAssertEqual(hero.rect.y, -(51 + 44), accuracy: 0.01)
    }

    // MARK: - the sealed leaves answer a tap

    private func targets(_ root: [String: Any]) -> InteractionMap {
        LayoutDecoder.interactions(flow: ["screens": [["root": root]]], screenIndex: 0)
    }

    func testAPhotoFrameClaimsItsTapAndCarriesWhatThePickerNeeds() {
        let map = targets([
            "type": "box",
            "children": [[
                "type": "photo_upload",
                "bind": ["save_to": "selfie"],
                "props": ["shape": "circle", "source": "camera"],
            ]],
        ])
        let photo = map.handler(for: "0")?.photoUpload
        XCTAssertEqual(photo?.saveTo, "selfie")
        XCTAssertEqual(photo?.shape, "circle")
        XCTAssertEqual(photo?.source, "camera")
    }

    func testASignInStackListsItsProvidersInOrder() {
        let map = targets([
            "type": "box",
            "children": [[
                "type": "signin",
                "bind": ["save_to": "account"],
                "props": [
                    "providers": [["provider": "apple"], ["provider": "email", "label": "Use email"]],
                    "advance_on_success": true,
                ],
            ]],
        ])
        let signIn = map.handler(for: "0")?.signIn
        XCTAssertEqual(signIn?.providers, ["apple", "email"])
        XCTAssertEqual(signIn?.labels["email"], "Use email")
        XCTAssertTrue(signIn?.advanceOnSuccess ?? false)
    }

    func testAPermissionRowNamesThePermissionItAsksFor() {
        let map = targets([
            "type": "box",
            "children": [[
                "type": "permission",
                "bind": ["save_to": "reminders"],
                "props": ["permission": "notifications", "advance_on_result": true],
            ]],
        ])
        XCTAssertEqual(map.handler(for: "0")?.permission?.permission, "notifications")
        XCTAssertEqual(map.handler(for: "0")?.permission?.saveTo, "reminders")
    }

    func testASliderCarriesTheRangeItCannotBeBuiltWithout() {
        let map = targets([
            "type": "box",
            "children": [[
                "type": "input",
                "bind": ["save_to": "spend"],
                "behavior": ["input": ["kind": "slider"]],
                "props": ["min": 400, "max": 9000, "step": 100],
            ]],
        ])
        let input = map.handler(for: "0")?.input
        XCTAssertEqual(input?.kind, "slider")
        XCTAssertEqual(input?.min, 400)
        XCTAssertEqual(input?.max, 9000)
        XCTAssertEqual(input?.step, 100)
    }

    // MARK: - which step of the sequence a screen is

    private func stepScreen(_ id: String, of sequence: String?) -> [String: Any] {
        var step: [String: Any] = ["index": 0]
        if let sequence { step["of"] = sequence }
        return [
            "id": id,
            "root": [
                "type": "box",
                "children": [["type": "box", "behavior": ["step": step]]],
            ],
        ]
    }

    func testStepIndexIsThePositionAmongTheScreensDrawingTheSequence() {
        let flow: [String: Any] = ["screens": [
            stepScreen("a", of: "setup"),
            ["id": "interlude", "root": ["type": "box"]],
            stepScreen("b", of: "setup"),
            stepScreen("c", of: "setup"),
        ]]
        XCTAssertEqual(LayoutDecoder.stepIndex(flow: flow, screenIndex: 0), 0)
        XCTAssertEqual(LayoutDecoder.stepIndex(flow: flow, screenIndex: 2), 1)
        XCTAssertEqual(LayoutDecoder.stepIndex(flow: flow, screenIndex: 3), 2)
    }

    func testAScreenThatDrawsNoSequenceHasNoStep() {
        let flow: [String: Any] = ["screens": [
            stepScreen("a", of: "setup"),
            ["id": "paywall", "root": ["type": "box"]],
        ]]
        XCTAssertNil(LayoutDecoder.stepIndex(flow: flow, screenIndex: 1))
    }

    func testTwoSequencesAreCountedSeparately() {
        let flow: [String: Any] = ["screens": [
            stepScreen("a", of: "setup"),
            stepScreen("x", of: "scan"),
            stepScreen("b", of: "setup"),
        ]]
        XCTAssertEqual(LayoutDecoder.stepIndex(flow: flow, screenIndex: 2), 1)
        XCTAssertEqual(LayoutDecoder.stepIndex(flow: flow, screenIndex: 1), 0)
    }

    func testTheStepStateFollowsTheIndexTheHostSupplies() throws {
        let root: [String: Any] = [
            "type": "box",
            "layout": ["mode": "row"],
            "children": (0..<3).map { i in
                [
                    "type": "box",
                    "self": ["width": 10, "height": 4],
                    "behavior": ["step": ["index": i, "of": "setup"]],
                    "states": ["completed": ["self": ["height": 6]], "current": ["self": ["height": 8]]],
                ] as [String: Any]
            },
        ]
        var input = LayoutInput()
        input.variables["__stepIndex"] = "1"
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(flow: ["screens": [["root": root]]], screenIndex: 0, input: input)
        )
        // completed, current, upcoming — read off the heights each state sets.
        XCTAssertEqual(tree.children.map(\.height), [.points(6), .points(8), .points(4)])
    }
}
