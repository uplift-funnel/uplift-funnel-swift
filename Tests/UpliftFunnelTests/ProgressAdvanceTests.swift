// A progress screen must never be a dead end.
//
// The package carries no ViewInspector, so a decision left inside a SwiftUI
// `body` is unreachable from here — which is why `progressAdvancePlan` exists
// as a pure function. These tests are the only thing that can catch this class
// of bug on iOS.

import XCTest
@testable import UpliftFunnel

final class ProgressAdvanceTests: XCTestCase {
    private func plan(
        _ props: [String: JSONValue], screenHasExit: Bool = true
    ) -> ProgressAdvancePlan {
        progressAdvancePlan(props: .object(props), screenHasExit: screenHasExit)
    }

    // MARK: - The reported hang

    func testBarWithAdvanceOnCompleteButNoDurationStillAdvances() {
        let p = plan(["style": .string("bar"), "advance_on_complete": .bool(true)])

        XCTAssertTrue(p.advances)
        // The bar can't self-fire without an animation to complete, so the
        // timeout wrapper has to carry it.
        XCTAssertFalse(p.selfFires)
        XCTAssertTrue(p.needsTimeout)
        XCTAssertEqual(p.effectiveMs, kDefaultProgressMs)
    }

    func testProgressThatIsTheOnlyExitAdvancesWithoutTheFlag() {
        // The reported shape: no advance_on_complete, no duration, no other way
        // off the screen. Every prop-keyed fix missed this one.
        let p = plan(["style": .string("bar")], screenHasExit: false)

        XCTAssertTrue(p.advances)
    }

    func testStaticGaugeNextToAnExitStaysPut() {
        // gentle-fitness/feature_condition and the catalog swipe rows.
        let p = plan(["style": .string("bar"), "value": .number(0.65)])

        XCTAssertFalse(p.advances)
    }

    // MARK: - Exactly one path, never two

    func testExactlyOnePathArmsForEveryShape() {
        let shapes: [(String, [String: JSONValue])] = [
            ("bar with duration", [
                "style": .string("bar"), "duration_ms": .number(1000),
                "advance_on_complete": .bool(true),
            ]),
            ("animated_list with items", [
                "style": .string("animated_list"),
                "items": .array([.string("a"), .string("b")]),
                "duration_ms": .number(1000), "advance_on_complete": .bool(true),
            ]),
            ("animated_list without items", [
                "style": .string("animated_list"),
                "duration_ms": .number(1000), "advance_on_complete": .bool(true),
            ]),
            ("spinner", [
                "style": .string("spinner"), "duration_ms": .number(1000),
                "advance_on_complete": .bool(true),
            ]),
            ("steps", [
                "style": .string("steps"), "advance_on_complete": .bool(true),
            ]),
            // The double-advance trap: an unknown style falls through to the
            // bar, which self-fires, while a style-keyed wrapper fired too.
            ("unknown style with duration", [
                "style": .string("circle"), "duration_ms": .number(1000),
                "advance_on_complete": .bool(true),
            ]),
            ("unknown style without duration", [
                "style": .string("circle"), "advance_on_complete": .bool(true),
            ]),
        ]

        for (name, props) in shapes {
            let p = plan(props)
            XCTAssertTrue(p.selfFires != p.needsTimeout, "\(name): both or neither")
            XCTAssertTrue(p.advances, name)
        }
    }

    func testSpinnerNeverSelfFiresEvenWithADuration() {
        // A spinner draws no completion — trusting a duration to mean "it
        // finishes on its own" would leave it with no advance at all.
        let p = plan([
            "style": .string("spinner"), "duration_ms": .number(1000),
            "advance_on_complete": .bool(true),
        ])

        XCTAssertFalse(p.selfFires)
        XCTAssertTrue(p.needsTimeout)
    }

    // MARK: - Duration parsing can't trap

    func testEffectiveDurationIsAlwaysSafeToConvert() {
        let cases: [(JSONValue, Int)] = [
            (.null, kDefaultProgressMs),
            (.number(0), kDefaultProgressMs),     // schema-valid, means "unset"
            (.number(-1), kDefaultProgressMs),    // used to trap on UInt64
            (.number(2500), 2500),
            (.number(2500.5), 2500),              // truncates, not discarded
            (.number(1e15), 600_000),             // used to overflow the * 1e6
            (.string("nope"), kDefaultProgressMs),
        ]

        for (raw, expected) in cases {
            let ms = effectiveProgressMs(raw)
            XCTAssertEqual(ms, expected, "\(raw)")
            XCTAssertTrue((0...600_000).contains(ms))
            // The conversion the renderer performs, which must not trap.
            _ = UInt64(ms) * 1_000_000
        }
    }
}
