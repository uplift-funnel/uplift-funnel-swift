import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// What a screen does when it is touched.
///
/// These replace the v2 `ChoiceLogicTests`. The subject is the same — how a
/// selection lands, how a multi-select toggles, what auto-advances — but v3
/// expresses it as `behavior.select` plus `behavior.group` on ordinary boxes
/// rather than a `choice` node type, so it is asserted against the document
/// instead of against a widget's internals.
final class InteractionTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func flow(_ root: [String: Any]) -> [String: Any] {
        ["screens": [["root": root]]]
    }

    // MARK: - bubbling

    /// A tap on a label is a tap on the card around it.
    ///
    /// The single most important rule here, and the one a flat hit test does
    /// not get for free: the topmost item under a finger is a text node or an
    /// emoji, and the thing that reacts is its ancestor. Without bubbling,
    /// tapping the word "Weekly" selects nothing while tapping the millimetre
    /// beside it works — which reads as a flaky tap target, not as a bug.
    func testATapOnALabelBubblesToTheCard() throws {
        let map = LayoutDecoder.interactions(
            flow: try fixture("wellness-onboarding"), screenIndex: 2
        )
        // The first option card, and the title text buried two levels inside.
        let handler = try XCTUnwrap(map.handler(for: "1.0.1.0"))
        XCTAssertEqual(handler.path, "1.0")
        XCTAssertEqual(handler.select?.value, "sleep")
    }

    /// A tap on nothing interactive stays nothing.
    func testATapOutsideAnyTargetDoesNothing() throws {
        let map = LayoutDecoder.interactions(
            flow: try fixture("wellness-onboarding"), screenIndex: 2
        )
        XCTAssertNil(map.handler(for: "0"), "the headline should not be tappable")
    }

    // MARK: - selection

    func testSingleSelectionReplaces() {
        var map = InteractionMap()
        map.groups["goal"] = GroupBehavior(name: "goal")
        let answers = map.answers(
            applying: SelectBehavior(group: "goal", value: "lose"),
            to: ["goal": "gain"]
        )
        XCTAssertEqual(answers["goal"], "lose")
    }

    /// A multi group toggles membership inside the canonical array encoding.
    func testMultiSelectionTogglesMembership() {
        var map = InteractionMap()
        map.groups["areas"] = GroupBehavior(name: "areas", multi: true)

        var answers: [String: String] = [:]
        answers = map.answers(applying: .init(group: "areas", value: "sleep"), to: answers)
        XCTAssertEqual(answers["areas"], #"["sleep"]"#)

        answers = map.answers(applying: .init(group: "areas", value: "stress"), to: answers)
        XCTAssertEqual(answers["areas"], #"["sleep","stress"]"#)

        // Choosing it again removes it — a tap on a chosen option unchooses.
        answers = map.answers(applying: .init(group: "areas", value: "sleep"), to: answers)
        XCTAssertEqual(answers["areas"], #"["stress"]"#)
    }

    /// The group may store somewhere other than its own name.
    func testAGroupCanNameWhereItSaves() {
        var map = InteractionMap()
        map.groups["plan"] = GroupBehavior(name: "plan", saveTo: "chosen_plan")
        let answers = map.answers(applying: .init(group: "plan", value: "weekly"), to: [:])
        XCTAssertEqual(answers["chosen_plan"], "weekly")
        XCTAssertNil(answers["plan"])
    }

    func testAutoAdvanceIsReadFromTheGroup() {
        var map = InteractionMap()
        map.groups["a"] = GroupBehavior(name: "a", autoAdvance: true)
        map.groups["b"] = GroupBehavior(name: "b")
        XCTAssertTrue(map.autoAdvances(.init(group: "a", value: "x")))
        XCTAssertFalse(map.autoAdvances(.init(group: "b", value: "x")))
        // A select naming a group nobody declared must not advance.
        XCTAssertFalse(map.autoAdvances(.init(group: "ghost", value: "x")))
    }

    // MARK: - the list encoding

    func testListEncodingRoundTrips() {
        XCTAssertEqual(decodeList(#"["a","b"]"#), ["a", "b"])
        XCTAssertEqual(decodeList("scalar"), ["scalar"])
        XCTAssertEqual(decodeList(""), [])
        XCTAssertEqual(decodeList(nil), [])
        XCTAssertEqual(encodeList([]), "[]")
        XCTAssertEqual(encodeList(["a"]), #"["a"]"#)
    }

    // MARK: - decoding

    func testTapActionsDecodeAsAListOrAString() throws {
        let asList = LayoutDecoder.interactions(flow: flow([
            "type": "box", "behavior": ["tap": ["next"]],
        ]), screenIndex: 0)
        XCTAssertEqual(asList.targets[""]?.actions, ["next"])

        let asString = LayoutDecoder.interactions(flow: flow([
            "type": "box", "behavior": ["tap": "next"],
        ]), screenIndex: 0)
        XCTAssertEqual(asString.targets[""]?.actions, ["next"])
    }

    func testInputDecodesItsFieldAndKeyboard() throws {
        let map = LayoutDecoder.interactions(
            flow: try fixture("wellness-onboarding"), screenIndex: 1
        )
        let field = try XCTUnwrap(map.targets.values.first { $0.input != nil }?.input)
        XCTAssertEqual(field.saveTo, "first_name")
        XCTAssertEqual(field.kind, "text")
    }

    /// A node with no behaviour is not in the map at all.
    ///
    /// The map is what the view consults on every tap, so a screen of six
    /// hundred decorative boxes should cost six entries, not six hundred.
    func testOnlyInteractiveNodesAreRecorded() throws {
        let map = LayoutDecoder.interactions(
            flow: try fixture("interior-paywall"), screenIndex: 0
        )
        XCTAssertFalse(map.targets.isEmpty)
        for target in map.targets.values {
            XCTAssertTrue(target.isInteractive, "\(target.path) is in the map doing nothing")
        }
    }

    // MARK: - the corpus's own groups

    func testThePaywallsPlanGroupIsFound() throws {
        let map = LayoutDecoder.interactions(
            flow: try fixture("interior-paywall"), screenIndex: 0
        )
        let group = try XCTUnwrap(map.groups["plan"], "the paywall declares a plan group")
        XCTAssertFalse(group.autoAdvance, "choosing a plan must not skip the paywall")

        let selects = map.targets.values.compactMap(\.select).filter { $0.group == "plan" }
        XCTAssertEqual(selects.count, 2, "weekly and monthly")
    }
}
