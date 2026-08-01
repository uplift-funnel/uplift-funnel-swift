import XCTest

@testable import UpliftLayout

/// `behavior.countdown`, which publishes `{{countdown.*}}` into its subtree.
///
/// The twin of `countdown.test.ts`. It was in the schema and in the inspector
/// — an author could set a duration and see an editor row for it — and NEITHER
/// renderer resolved the tokens, so the subtree drew the literal braces.
///
/// The clock arrives as an input rather than being read here. That is not
/// fussiness: the published values are TEXT, text is measured, and a decoder
/// that called `Date()` would return a different layout on every solve and
/// could never be held to a recorded baseline.
final class CountdownTests: XCTestCase {
    private func vars(_ spec: [String: Any], now: Double, entered: Double) -> [String: String] {
        LayoutDecoder.countdownVars(
            spec,
            input: LayoutInput(now: now, screenEnteredAt: entered)
        )
    }

    func testCountsDownFromScreenEntry() {
        // 10 minutes, 90 seconds in.
        let v = vars(["duration_ms": 600_000], now: 90_000, entered: 0)
        XCTAssertEqual(v["countdown.minutes"], "08")
        XCTAssertEqual(v["countdown.seconds"], "30")
        XCTAssertEqual(v["countdown.hours"], "00")
        XCTAssertEqual(v["countdown.days"], "0")
    }

    func testPadsToTwoDigits() {
        // The reason padding exists: "9" and "09" are different widths, and the
        // text is measured, so an unpadded clock shifts its own layout once a
        // second.
        let v = vars(["duration_ms": 9_000], now: 0, entered: 0)
        XCTAssertEqual(v["countdown.seconds"], "09")
    }

    func testDaysAreNotPadded() {
        let v = vars(["duration_ms": 3 * 86_400_000], now: 0, entered: 0)
        XCTAssertEqual(v["countdown.days"], "3")
    }

    func testStopsAtZeroRatherThanGoingNegative() {
        let v = vars(["duration_ms": 5_000], now: 60_000, entered: 0)
        XCTAssertEqual(v["countdown.seconds"], "00")
        XCTAssertEqual(v["countdown.minutes"], "00")
    }

    func testAbsoluteTargetBeatsDuration() {
        let target = "2026-01-01T00:00:00Z"
        let at = ISO8601DateFormatter().date(from: target)!.timeIntervalSince1970 * 1000
        let v = vars(["target": target], now: at - 3_661_000, entered: 0)
        XCTAssertEqual(v["countdown.hours"], "01")
        XCTAssertEqual(v["countdown.minutes"], "01")
        XCTAssertEqual(v["countdown.seconds"], "01")
    }

    func testAcceptsFractionalSeconds() {
        // `.withFractionalSeconds` rejects a string without them rather than
        // tolerating it, so the formatter that parses one cannot be the only one.
        let v = vars(["target": "2026-01-01T00:00:00.500Z"], now: 0, entered: 0)
        XCTAssertNotNil(v["countdown.days"])
        XCTAssertNotEqual(v["countdown.days"], "0", "a 2026 target should be days away from epoch 0")
    }

    func testAZeroClockShowsTheFullDuration() {
        // The golden route has no clock. Showing the full length keeps the
        // recorded frame stable AND realistic — a deadline long past would
        // record "00:00", which is not the width the real screen has.
        let v = vars(["duration_ms": 600_000], now: 0, entered: 1_700_000_000_000)
        XCTAssertEqual(v["countdown.minutes"], "10")
        XCTAssertEqual(v["countdown.seconds"], "00")
    }

    func testTokensReachTheSubtreeAsMeasuredText() throws {
        // The point of the whole feature: an ordinary text node under the
        // countdown box resolves, and one outside it does not.
        let root: [String: Any] = [
            "type": "box",
            "children": [
                [
                    "type": "box",
                    "behavior": ["countdown": ["duration_ms": 125_000]],
                    "children": [["type": "text", "props": ["value": "{{countdown.minutes}}:{{countdown.seconds}}"]]],
                ],
                ["type": "text", "props": ["value": "{{countdown.seconds}}"]],
            ],
        ]
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(
                screen: ["root": root],
                input: LayoutInput(now: 5_000, screenEnteredAt: 0)
            )
        )
        XCTAssertEqual(tree.children[0].children[0].text?.text, "02:00")
        XCTAssertEqual(
            tree.children[1].text?.text,
            "{{countdown.seconds}}",
            "a token outside the countdown box must stay literal, not resolve to 00"
        )
    }

    // MARK: - completion

    /// `countdown.done` is ABSENT while the timer runs rather than `"false"`.
    ///
    /// Absence is what makes the plain `is_set` operator work, and `is_set` is
    /// the one comparison every evaluator on every platform already spells the
    /// same way — so an author gates a CTA on it without anything else in the
    /// stack having to change.
    func testDoneIsAbsentWhileRunningAndSetAtZero() {
        XCTAssertNil(vars(["duration_ms": 10_000], now: 4_000, entered: 0)["countdown.done"])
        XCTAssertEqual(vars(["duration_ms": 10_000], now: 10_000, entered: 0)["countdown.done"], "true")
        XCTAssertEqual(vars(["duration_ms": 10_000], now: 99_000, entered: 0)["countdown.done"], "true")
    }

    func testRemainingMillisecondsArePublished() {
        XCTAssertEqual(vars(["duration_ms": 10_000], now: 2_500, entered: 0)["countdown.remaining_ms"], "7500")
        XCTAssertEqual(vars(["duration_ms": 10_000], now: 60_000, entered: 0)["countdown.remaining_ms"], "0")
    }

    /// A screen that finishes on the frame it appears is a screen nobody sees.
    /// `duration_ms` is optional and `0` is legal, but neither means "advance
    /// instantly" — the Dart engine learned this once and the lesson did not
    /// survive the port to native.
    func testAnAbsentOrNonPositiveDurationFallsBackToThreeSeconds() {
        XCTAssertEqual(LayoutDecoder.duration([:]), 3000)
        XCTAssertEqual(LayoutDecoder.duration(["duration_ms": 0]), 3000)
        XCTAssertEqual(LayoutDecoder.duration(["duration_ms": -1]), 3000)
        XCTAssertEqual(LayoutDecoder.duration(["duration_ms": Double.nan]), 3000)
        XCTAssertEqual(LayoutDecoder.duration(["duration_ms": 2_600]), 2600)
        XCTAssertNil(
            vars(["duration_ms": 0], now: 1_000, entered: 0)["countdown.done"],
            "a zero duration must run the fallback, not complete on arrival"
        )
    }

    /// The whole point of the feature, and the bug it closes: a loading screen
    /// declares where to go and, until now, nothing ever took it there.
    func testACompletedCountdownYieldsItsAction() {
        let flow: [String: Any] = ["screens": [["root": [
            "type": "box",
            "children": [[
                "type": "box",
                "behavior": ["countdown": ["duration_ms": 2_600, "on_complete": "next"]],
            ]],
        ]]]]
        func action(now: Double) -> String? {
            LayoutDecoder.countdownComplete(
                flow: flow, screenIndex: 0,
                input: LayoutInput(now: now, screenEnteredAt: 0)
            )
        }
        XCTAssertNil(action(now: 2_000), "still running")
        XCTAssertEqual(action(now: 2_600), "next")
    }

    func testACountdownWithoutAnActionYieldsNothing() {
        let flow: [String: Any] = ["screens": [["root": [
            "type": "box",
            "behavior": ["countdown": ["duration_ms": 1_000]],
        ]]]]
        XCTAssertNil(
            LayoutDecoder.countdownComplete(
                flow: flow, screenIndex: 0, input: LayoutInput(now: 9_000, screenEnteredAt: 0)
            ),
            "a presentational countdown must not advance a screen on its own"
        )
    }

    /// A CTA hidden until the timer finishes — the mechanism an author uses,
    /// end to end, with no new condition operator and no new variable channel.
    func testDoneGatesAVisibleWhen() throws {
        let root: [String: Any] = [
            "type": "box",
            "behavior": ["countdown": ["duration_ms": 2_600, "on_complete": "next"]],
            "children": [[
                "type": "text",
                "props": ["value": "Meet them"],
                "visible": ["when": ["var": "countdown.done", "op": "is_set"]],
            ]],
        ]
        func drawn(now: Double) throws -> Bool {
            let tree = try XCTUnwrap(
                LayoutDecoder.layoutTree(
                    screen: ["root": root],
                    input: LayoutInput(now: now, screenEnteredAt: 0)
                )
            )
            return !tree.children.isEmpty
        }
        XCTAssertFalse(try drawn(now: 1_000), "the button is not there while the crew is briefing")
        XCTAssertTrue(try drawn(now: 2_600), "and it is there the moment they are briefed")
    }
}
