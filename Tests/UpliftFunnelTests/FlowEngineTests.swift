import XCTest
@testable import UpliftFunnel

// Port of the Flutter SDK's flow_engine_test.dart — the behavioral contract
// for branching, back navigation, terminal transitions and context vars.

func buildBranchingFlow() throws -> FunnelFlow {
    try FunnelFlow(json: try JSONValue.parse("""
    {
      "schema_version": 1,
      "id": "test-flow",
      "entry_screen_id": "welcome",
      "variables": [
        {"name": "goal", "type": "string"},
        {"name": "motivation", "type": "number"}
      ],
      "screens": [
        {"id": "welcome", "archetype": "welcome",
         "transitions": [{"go": "goal_q"}]},
        {"id": "goal_q", "archetype": "single_choice",
         "transitions": [
           {"if": {"var": "goal", "op": "==", "value": "lose"}, "go": "lose_path"},
           {"go": "general_path"}
         ]},
        {"id": "lose_path", "archetype": "scale",
         "transitions": [{"go": "finale"}]},
        {"id": "general_path", "archetype": "scale",
         "transitions": [{"go": "finale"}]},
        {"id": "finale", "archetype": "finale", "transitions": []}
      ]
    }
    """))
}

final class FlowEngineTests: XCTestCase {
    func testStartsAtEntryScreenId() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertEqual(engine.currentScreenId, "welcome")
    }

    func testLinearAdvanceFollowsDefaultTransition() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertEqual(try engine.advance(), .advanced(screenId: "goal_q"))
    }

    func testBranchesOnGoalLose() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = try engine.advance()
        try engine.setVariable("goal", "lose")
        XCTAssertEqual(try engine.advance(), .advanced(screenId: "lose_path"))
    }

    func testFallsThroughToGeneralPathWhenGoalDoesNotMatch() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = try engine.advance()
        try engine.setVariable("goal", "gain")
        XCTAssertEqual(try engine.advance(), .advanced(screenId: "general_path"))
    }

    func testCompletesImplicitlyOnScreenWithNoTransitions() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = try engine.advance()
        try engine.setVariable("goal", "lose")
        _ = try engine.advance()
        _ = try engine.advance()
        XCTAssertEqual(try engine.advance(), .completed(reason: "completed"))
        XCTAssertTrue(engine.isComplete)
    }

    func testGoBackPopsHistory() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = try engine.advance()
        XCTAssertEqual(engine.currentScreenId, "goal_q")
        XCTAssertTrue(engine.goBack())
        XCTAssertEqual(engine.currentScreenId, "welcome")
    }

    func testGoBackNoOpWhenHistoryEmpty() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertFalse(engine.goBack())
        XCTAssertEqual(engine.currentScreenId, "welcome")
    }

    func testThrowsWhenUnmatchedAndNoDefault() throws {
        let flow = try FunnelFlow(json: try JSONValue.parse("""
        {
          "schema_version": 1, "id": "unmatched", "entry_screen_id": "a",
          "variables": [{"name": "goal", "type": "string"}],
          "screens": [
            {"id": "a", "archetype": "single_choice",
             "transitions": [
               {"if": {"var": "goal", "op": "==", "value": "never_chosen"}, "go": "a"}
             ]}
          ]
        }
        """))
        let engine = try FlowEngine(flow: flow)
        try engine.setVariable("goal", "something_else")
        XCTAssertThrowsError(try engine.advance()) {
            XCTAssertTrue($0 is FlowEngineError)
        }
    }

    func testEndReasonTerminatesWithProvidedReason() throws {
        let flow = try FunnelFlow(json: try JSONValue.parse("""
        {
          "schema_version": 1, "id": "terminator", "entry_screen_id": "a",
          "screens": [
            {"id": "a", "archetype": "welcome",
             "transitions": [{"go": "end:skipped"}]}
          ]
        }
        """))
        let engine = try FlowEngine(flow: flow)
        XCTAssertEqual(try engine.advance(), .completed(reason: "skipped"))
    }

    func testNumericComparison() throws {
        let flow = try FunnelFlow(json: try JSONValue.parse("""
        {
          "schema_version": 1, "id": "numeric", "entry_screen_id": "a",
          "variables": [{"name": "age", "type": "number"}],
          "screens": [
            {"id": "a", "archetype": "scale",
             "transitions": [
               {"if": {"var": "age", "op": ">=", "value": 18}, "go": "b"},
               {"go": "c"}
             ]},
            {"id": "b", "archetype": "finale", "transitions": []},
            {"id": "c", "archetype": "finale", "transitions": []}
          ]
        }
        """))
        let adult = try FlowEngine(flow: flow)
        try adult.setVariable("age", 25)
        XCTAssertEqual(try adult.advance(), .advanced(screenId: "b"))

        let minor = try FlowEngine(flow: flow)
        try minor.setVariable("age", 12)
        XCTAssertEqual(try minor.advance(), .advanced(screenId: "c"))
    }

    func testContextVariablesReadFromContext() throws {
        let flow = try FunnelFlow(json: try JSONValue.parse("""
        {
          "schema_version": 1, "id": "platform", "entry_screen_id": "a",
          "screens": [
            {"id": "a", "archetype": "welcome",
             "transitions": [
               {"if": {"var": "device.platform", "op": "==", "value": "ios"}, "go": "ios_screen"},
               {"go": "other_screen"}
             ]},
            {"id": "ios_screen", "archetype": "finale", "transitions": []},
            {"id": "other_screen", "archetype": "finale", "transitions": []}
          ]
        }
        """))
        let engine = try FlowEngine(
            flow: flow, contextVariables: ["device.platform": "ios"])
        XCTAssertEqual(try engine.advance(), .advanced(screenId: "ios_screen"))
    }

    // MARK: jumpTo / complete

    func testJumpToMovesAndRecordsHistory() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertEqual(try engine.jumpTo("lose_path"), .advanced(screenId: "lose_path"))
        XCTAssertEqual(engine.currentScreenId, "lose_path")
        XCTAssertEqual(engine.history, ["welcome"])
    }

    func testJumpToThrowsForUnknownScreen() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertThrowsError(try engine.jumpTo("nope"))
    }

    func testJumpToThrowsOnceComplete() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = engine.complete("done")
        XCTAssertThrowsError(try engine.jumpTo("goal_q"))
    }

    func testCompleteSetsReasonAndIsIdempotent() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        XCTAssertEqual(engine.complete("closed"), .completed(reason: "closed"))
        XCTAssertTrue(engine.isComplete)
        // Second call doesn't override the original reason.
        XCTAssertEqual(engine.complete("skipped"), .completed(reason: "closed"))
    }

    func testSetVariableThrowsOnCompletedFlow() throws {
        let engine = try FlowEngine(flow: try buildBranchingFlow())
        _ = engine.complete("done")
        XCTAssertThrowsError(try engine.setVariable("goal", "x"))
    }

    func testEngineInitThrowsWhenEntryScreenMissing() throws {
        let flow = try FunnelFlow(json: try JSONValue.parse("""
        {"schema_version": 1, "id": "bad", "entry_screen_id": "ghost",
         "screens": [{"id": "a", "transitions": []}]}
        """))
        XCTAssertThrowsError(try FlowEngine(flow: flow))
    }
}

@MainActor
final class FlowSessionTests: XCTestCase {
    private func makeSession() throws -> FlowSession {
        try FlowSession(flow: try buildBranchingFlow())
    }

    func testEmitsStartedAfterConstruction() async throws {
        let session = try makeSession()
        var started: FlowEvent?
        session.addEventListener { event in
            if case .started = event { started = event }
        }
        // The started event is deferred one hop; yield.
        await Task.yield()
        try await Task.sleep(nanoseconds: 10_000_000)
        guard case .started(_, _, let entry)? = started else {
            return XCTFail("No FlowStarted observed")
        }
        XCTAssertEqual(entry, "welcome")
    }

    func testEmitsEventsThroughTheFlow() async throws {
        let session = try makeSession()
        var screenChanges = 0
        var sawVariableSet = false
        var sawCompleted = false
        session.addEventListener { event in
            switch event {
            case .screenChanged: screenChanges += 1
            case .variableSet: sawVariableSet = true
            case .completed: sawCompleted = true
            default: break
            }
        }
        session.advance()
        session.setVariable("goal", "lose")
        session.advance()
        session.setVariable("motivation", 8)
        session.advance()
        session.advance()
        XCTAssertEqual(screenChanges, 3)
        XCTAssertTrue(sawVariableSet)
        XCTAssertTrue(sawCompleted)
    }

    func testCanGoBackReflectsHistory() throws {
        let session = try makeSession()
        XCTAssertFalse(session.canGoBack)
        session.advance()
        XCTAssertTrue(session.canGoBack)
        session.goBack()
        XCTAssertFalse(session.canGoBack)
    }

    func testHandleActionNextAndSubmitAdvance() throws {
        let next = try makeSession()
        next.handleAction("next")
        XCTAssertEqual(next.currentScreen.id, "goal_q")

        let submit = try makeSession()
        submit.handleAction("submit")
        XCTAssertEqual(submit.currentScreen.id, "goal_q")
    }

    func testHandleActionBackStepsBackward() throws {
        let session = try makeSession()
        session.handleAction("next")
        session.handleAction("back")
        XCTAssertEqual(session.currentScreen.id, "welcome")
    }

    func testHandleActionGoJumpsDirectly() throws {
        let session = try makeSession()
        session.handleAction("go:lose_path")
        XCTAssertEqual(session.currentScreen.id, "lose_path")
        XCTAssertTrue(session.canGoBack)
    }

    func testHandleActionEndCompletesImmediately() throws {
        let session = try makeSession()
        var reason: String?
        session.addEventListener { event in
            if case .completed(_, _, let r, _) = event { reason = r }
        }
        session.handleAction("end:skipped")
        XCTAssertTrue(session.completed)
        XCTAssertEqual(reason, "skipped")
    }

    func testHandleActionUnrecognizedEmitsCustomEvent() throws {
        let session = try makeSession()
        var name: String?
        session.addEventListener { event in
            if case .custom(_, _, let n, _) = event { name = n }
        }
        session.handleAction("url:https://example.com")
        XCTAssertEqual(name, "url:https://example.com")
    }

    func testCompleteEndsWithoutEvaluatingTransitions() throws {
        let session = try makeSession()
        var reason: String?
        session.addEventListener { event in
            if case .completed(_, _, let r, _) = event { reason = r }
        }
        session.complete("closed")
        XCTAssertTrue(session.completed)
        XCTAssertEqual(session.currentScreen.id, "welcome")
        XCTAssertEqual(reason, "closed")
    }

    // MARK: - Direction bookkeeping (port of nav_transition_test.dart)

    func testLastNavWasBackResetsOnForwardNav() throws {
        let session = try makeSession()
        XCTAssertFalse(session.lastNavWasBack)
        session.advance()
        XCTAssertFalse(session.lastNavWasBack)
        session.goBack()
        XCTAssertTrue(session.lastNavWasBack)
        session.advance()
        XCTAssertFalse(session.lastNavWasBack)
        session.handleAction("go:lose_path")
        XCTAssertFalse(session.lastNavWasBack)
    }

    // MARK: - Keystroke coalescing (port of variable_commit_test.dart)

    private func collectVariableSets(
        _ session: FlowSession
    ) -> () -> [(screenId: String, name: String, value: JSONValue)] {
        var sets: [(String, String, JSONValue)] = []
        session.addEventListener { event in
            if case .variableSet(_, _, let screenId, let name, let value) = event {
                sets.append((screenId, name, value))
            }
        }
        return { sets }
    }

    func testLocalWritesEmitNothingUntilNavigationFlush() throws {
        let session = try makeSession()
        let sets = collectVariableSets(session)
        session.advance() // -> goal_q

        session.setVariableLocal("goal", "l")
        session.setVariableLocal("goal", "lo")
        session.setVariableLocal("goal", "lose")
        XCTAssertTrue(sets().isEmpty,
                      "per-keystroke writes must not emit analytics events")
        XCTAssertEqual(session.variables["goal"], "lose")

        session.advance() // flush + branch on the typed value
        let flushed = sets()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].name, "goal")
        XCTAssertEqual(flushed[0].value, "lose")
        XCTAssertEqual(flushed[0].screenId, "goal_q",
                       "value attributes to the screen it was typed on")
        XCTAssertEqual(session.currentScreen.id, "lose_path")
    }

    func testCommitVariableFlushesOnceAndNavigationAddsNothing() throws {
        let session = try makeSession()
        let sets = collectVariableSets(session)
        session.advance()

        session.setVariableLocal("goal", "lose")
        session.commitVariable("goal") // editing end
        XCTAssertEqual(sets().count, 1)

        session.advance()
        XCTAssertEqual(sets().count, 1,
                       "navigation must not re-emit the committed value")
    }

    func testAbandonFlushesPendingTypedValue() throws {
        let session = try makeSession()
        let sets = collectVariableSets(session)
        session.advance()
        session.setVariableLocal("goal", "lose")
        session.abandon()
        XCTAssertEqual(sets().count, 1)
        XCTAssertEqual(sets()[0].value, "lose")
    }

    func testCommittedWriteSupersedesPendingLocalWrites() throws {
        let session = try makeSession()
        let sets = collectVariableSets(session)
        session.advance()
        session.setVariableLocal("goal", "los")
        session.setVariable("goal", "lose") // e.g. a choice tap on the same var
        XCTAssertEqual(sets().count, 1)
        session.advance()
        XCTAssertEqual(sets().count, 1,
                       "the committed write cleared the pending local one")
    }
}
