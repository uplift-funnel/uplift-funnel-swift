import XCTest
@testable import UpliftLayout

/// Selection, product tokens and conditions — asserted through the JSON
/// DECODER, every time.
///
/// This file exists because of how the multi-select bug survived. The suite
/// next door names multi-select in three test titles and every one of them
/// builds `GroupBehavior(name:multi:)` in Swift, so it asserted that the toggle
/// arithmetic was right — which it was — while the decoder read a `multi`
/// boolean that no document has ever contained. The document says
/// `behavior.group.mode: "multi"`. Nothing that starts from a Swift value can
/// see that class of mistake, so nothing here does.
final class DecodedSelectionTests: XCTestCase {
    private struct Ruler: TextMeasuring {
        func measure(_ run: TextRunSpec) -> TextMetrics {
            let w = Double(run.text.count) * 10
            return TextMetrics(lines: [TextLine(text: run.text, width: w)], width: w, height: 20)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { Double(run.text.count) * 10 }
    }

    private func flow(_ root: [String: Any]) -> [String: Any] {
        ["screens": [["root": root]]]
    }

    /// One option box. `states.selected` changes its height, so a frame is a
    /// readout of which state the decoder resolved.
    private func option(_ group: String, _ value: String) -> [String: Any] {
        [
            "type": "box",
            "self": ["height": 10],
            "behavior": ["select": ["group": group, "value": value]],
            "states": ["selected": ["self": ["height": 99]]],
        ]
    }

    private func heights(_ root: [String: Any], selections: [String: String]) throws -> [String: Double] {
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(
                flow: flow(root), screenIndex: 0,
                input: LayoutInput(selections: selections)
            )
        )
        let solved = try FlexSolver(measurer: Ruler()).solve(
            root: tree,
            viewport: Viewport(size: Size2D(width: 390, height: 800), safeTop: 0)
        )
        return Dictionary(solved.map { ($0.path, $0.rect.height) }) { a, _ in a }
    }

    private func isSelected(_ heights: [String: Double], _ path: String) -> Bool {
        heights[path] == 99
    }

    // MARK: - the flag the document actually carries

    func testModeMultiIsReadFromTheDocument() {
        let map = LayoutDecoder.interactions(
            flow: flow([
                "type": "box",
                "bind": ["save_to": "areas"],
                "behavior": ["group": ["name": "areas", "mode": "multi"]],
            ]),
            screenIndex: 0
        )
        XCTAssertEqual(map.groups["areas"]?.multi, true)
    }

    func testModeSingleAndAnAbsentModeAreBothSingle() {
        func multi(_ group: [String: Any]) -> Bool? {
            LayoutDecoder.interactions(
                flow: flow(["type": "box", "behavior": ["group": group]]), screenIndex: 0
            ).groups["g"]?.multi
        }
        XCTAssertEqual(multi(["name": "g", "mode": "single"]), false)
        XCTAssertEqual(multi(["name": "g"]), false)
    }

    func testMinAndMaxAreDecoded() {
        let map = LayoutDecoder.interactions(
            flow: flow([
                "type": "box",
                "behavior": ["group": ["name": "areas", "mode": "multi", "min": 1, "max": 3]],
            ]),
            screenIndex: 0
        )
        XCTAssertEqual(map.groups["areas"]?.min, 1)
        XCTAssertEqual(map.groups["areas"]?.max, 3)
    }

    // MARK: - a multi-select lights up every option it holds

    /// The second half of the bug. Even with `multi` decoded, the state was
    /// resolved with `chosen == value` — and no JSON array is string-equal to
    /// one of its own members, so every card stayed unselected while the answer
    /// underneath was correct.
    func testEveryChosenOptionInAMultiGroupIsSelected() throws {
        let root: [String: Any] = [
            "type": "box",
            "bind": ["save_to": "areas"],
            "behavior": ["group": ["name": "areas", "mode": "multi"]],
            "children": [option("areas", "sleep"), option("areas", "stress"), option("areas", "focus")],
        ]
        let h = try heights(root, selections: ["areas": #"["sleep","focus"]"#])
        XCTAssertTrue(isSelected(h, "0"), "sleep is in the answer")
        XCTAssertFalse(isSelected(h, "1"), "stress is not")
        XCTAssertTrue(isSelected(h, "2"), "focus is in the answer")
    }

    func testAnEmptyMultiAnswerSelectsNothing() throws {
        let root: [String: Any] = [
            "type": "box",
            "bind": ["save_to": "areas"],
            "behavior": ["group": ["name": "areas", "mode": "multi"]],
            "children": [option("areas", "sleep")],
        ]
        XCTAssertFalse(isSelected(try heights(root, selections: ["areas": "[]"]), "0"))
    }

    func testAScalarAnswerStillSelectsByEquality() throws {
        let root: [String: Any] = [
            "type": "box",
            "behavior": ["group": ["name": "plan"]],
            "children": [option("plan", "yearly"), option("plan", "monthly")],
        ]
        let h = try heights(root, selections: ["plan": "monthly"])
        XCTAssertFalse(isSelected(h, "0"))
        XCTAssertTrue(isSelected(h, "1"))
    }

    // MARK: - a group stored somewhere other than its own name

    /// The tap writes to `bind.save_to`; the state used to read the group's
    /// NAME. Three of the four groups in the flow this was found in happened to
    /// use the same string for both and worked; the one that did not could be
    /// tapped all day and never showed a thing.
    func testAGroupBoundElsewhereStillHighlights() throws {
        let root: [String: Any] = [
            "type": "box",
            "bind": ["save_to": "business_category"],
            "behavior": ["group": ["name": "category"]],
            "children": [option("category", "retail"), option("category", "saas")],
        ]
        let h = try heights(root, selections: ["business_category": "saas"])
        XCTAssertFalse(isSelected(h, "0"))
        XCTAssertTrue(isSelected(h, "1"), "the answer is under save_to, not under the group name")
    }

    /// And the write side agrees with it — one key, resolved the same way.
    func testAGroupBoundElsewhereWritesToItsBinding() {
        let map = LayoutDecoder.interactions(
            flow: flow([
                "type": "box",
                "bind": ["save_to": "business_category"],
                "behavior": ["group": ["name": "category"]],
                "children": [option("category", "retail")],
            ]),
            screenIndex: 0
        )
        let answers = map.answers(
            applying: SelectBehavior(group: "category", value: "retail"), to: [:]
        )
        XCTAssertEqual(answers["business_category"], "retail")
        XCTAssertNil(answers["category"], "writing the group name would strand every downstream read")
    }

    /// An option declared outside its group box resolves the same key. This is
    /// why the table is collected screen-wide rather than scoped down the tree:
    /// the write side has always resolved groups flat, and a read side that
    /// resolved by ancestry would disagree with it here.
    func testAnOptionOutsideItsGroupBoxStillResolves() throws {
        let root: [String: Any] = [
            "type": "box",
            "children": [
                [
                    "type": "box",
                    "bind": ["save_to": "business_category"],
                    "behavior": ["group": ["name": "category"]],
                ],
                option("category", "retail"),
            ],
        ]
        XCTAssertTrue(isSelected(try heights(root, selections: ["business_category": "retail"]), "1"))
    }

    // MARK: - max

    func testAFullMultiGroupRefusesAnotherValue() {
        let map = LayoutDecoder.interactions(
            flow: flow([
                "type": "box",
                "behavior": ["group": ["name": "areas", "mode": "multi", "max": 2]],
            ]),
            screenIndex: 0
        )
        let held = [String: String]()
        let one = map.answers(applying: SelectBehavior(group: "areas", value: "a"), to: held)
        let two = map.answers(applying: SelectBehavior(group: "areas", value: "b"), to: one)
        let three = map.answers(applying: SelectBehavior(group: "areas", value: "c"), to: two)
        XCTAssertEqual(three["areas"], two["areas"], "the third value is refused, not swapped in")

        // Deselecting is never refused, and frees a slot.
        let back = map.answers(applying: SelectBehavior(group: "areas", value: "a"), to: three)
        XCTAssertEqual(decodeList(back["areas"]), ["b"])
    }

    // MARK: - product tokens

    private func text(_ root: [String: Any], products: [String: [String: String]]) throws -> String {
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(
                flow: flow(root), screenIndex: 0,
                input: LayoutInput(products: products)
            )
        )
        func find(_ n: LayoutNode) -> String? {
            if let t = n.text { return t.text }
            for c in n.children { if let found = find(c) { return found } }
            return nil
        }
        return try XCTUnwrap(find(tree))
    }

    private var priceCard: [String: Any] {
        [
            "type": "box",
            "behavior": ["product": ["ref": "yearly_pro"], "select": ["group": "plan", "value": "y"]],
            "children": [["type": "text", "props": ["value": "{{product.price}}/{{product.period}}"]]],
        ]
    }

    func testAProductBoundCardRendersTheStorePrice() throws {
        let drawn = try text(priceCard, products: ["yearly_pro": ["price": "€8.99", "period": "year"]])
        XCTAssertEqual(drawn, "€8.99/year")
    }

    /// The paywall bug, stated as an assertion: with no products registered the
    /// card must draw nothing where the price goes. It used to draw
    /// `{{product.price}}` — seventeen unbreakable characters, which is also
    /// what squeezed the card's grow column to nothing and made the row tall
    /// and empty.
    func testAProductTokenWithNoStoreDataDrawsNothing() throws {
        let drawn = try text(priceCard, products: [:])
        XCTAssertFalse(drawn.contains("{{"), "a user must never be shown a template token: \(drawn)")
        XCTAssertEqual(drawn, "/")
    }

    /// And the rule stays confined to that one namespace. An ordinary variable
    /// keeps its braces, because the corpus is measured against a browser
    /// recording that has them.
    func testAnOrdinaryTokenKeepsItsBraces() throws {
        let root: [String: Any] = [
            "type": "box",
            "children": [["type": "text", "props": ["value": "Hi {{first_name}}"]]],
        ]
        XCTAssertEqual(try text(root, products: [:]), "Hi {{first_name}}")
    }

    // MARK: - conditions

    /// `is_not_set` is the schema's spelling and the web painter's; the solver
    /// only knew `not_set` and fell through to "keep the node". Solve and paint
    /// disagreed on the web, and on device the node was never hidden at all.
    func testTheSchemaSpellingOfIsNotSetHides() throws {
        let root: [String: Any] = [
            "type": "box",
            "children": [[
                "type": "box",
                "self": ["height": 10],
                "visible": ["when": ["var": "answered", "op": "is_not_set"]],
            ]],
        ]
        XCTAssertNil(try heights(root, selections: ["answered": "yes"])["0"])
        XCTAssertNotNil(try heights(root, selections: [:])["0"])
    }

    func testNumericComparisonsAreEvaluatedRatherThanIgnored() throws {
        func visible(_ op: String, _ value: Int, answer: String) throws -> Bool {
            let root: [String: Any] = [
                "type": "box",
                "children": [[
                    "type": "box",
                    "self": ["height": 10],
                    "visible": ["when": ["var": "age", "op": op, "value": value]],
                ]],
            ]
            return try heights(root, selections: ["age": answer])["0"] != nil
        }
        XCTAssertTrue(try visible(">=", 18, answer: "18"))
        XCTAssertFalse(try visible(">=", 18, answer: "17"))
        XCTAssertTrue(try visible("<", 18, answer: "17"))
        XCTAssertFalse(try visible(">", 18, answer: "18"))
        XCTAssertFalse(try visible(">", 18, answer: "not a number"))
    }

    func testNotContainsIsEvaluated() throws {
        let root: [String: Any] = [
            "type": "box",
            "children": [[
                "type": "box",
                "self": ["height": 10],
                "visible": ["when": ["var": "tasks", "op": "not_contains", "value": "email"]],
            ]],
        ]
        XCTAssertNil(try heights(root, selections: ["tasks": #"["email","social"]"#])["0"])
        XCTAssertNotNil(try heights(root, selections: ["tasks": #"["social"]"#])["0"])
    }
}
