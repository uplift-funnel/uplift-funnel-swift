import XCTest
@testable import FunnelOnboarding

final class FlowEngineTests: XCTestCase {
    private func buildBranchingFlow() throws -> Flow {
        let json = """
        {
          "schema_version": 1,
          "id": "test-flow",
          "entry_screen_id": "welcome",
          "variables": [
            { "name": "goal", "type": "string" }
          ],
          "screens": [
            { "id": "welcome", "archetype": "welcome",
              "content": { "title": "Hi", "cta_label": "Go" },
              "transitions": [{ "go": "goal_q" }] },
            { "id": "goal_q", "archetype": "single_choice",
              "content": {
                "question": "Goal?", "save_to": "goal",
                "options": [
                  { "value": "lose", "label": "Lose" },
                  { "value": "gain", "label": "Gain" }
                ]
              },
              "transitions": [
                { "if": { "var": "goal", "op": "==", "value": "lose" }, "go": "lose_path" },
                { "go": "general_path" }
              ] },
            { "id": "lose_path", "archetype": "finale",
              "content": { "title": "Lose plan", "cta_label": "Ok" }, "transitions": [] },
            { "id": "general_path", "archetype": "finale",
              "content": { "title": "General plan", "cta_label": "Ok" }, "transitions": [] }
          ]
        }
        """
        return try Flow.decode(fromJSONString: json)
    }

    func testStartsAtEntryScreen() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        XCTAssertEqual(engine.currentScreenId, "welcome")
    }

    func testLinearAdvance() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        let step = try engine.advance()
        if case .advanced(let id) = step { XCTAssertEqual(id, "goal_q") }
        else { XCTFail("Expected advanced step") }
    }

    func testBranchOnGoal() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        try engine.advance()
        try engine.setVariable("goal", AnyHashable("lose"))
        let step = try engine.advance()
        if case .advanced(let id) = step { XCTAssertEqual(id, "lose_path") }
        else { XCTFail("Expected advanced") }
    }

    func testFallThrough() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        try engine.advance()
        try engine.setVariable("goal", AnyHashable("gain"))
        let step = try engine.advance()
        if case .advanced(let id) = step { XCTAssertEqual(id, "general_path") }
        else { XCTFail("Expected advanced") }
    }

    func testGoBackPopsHistory() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        try engine.advance()
        XCTAssertEqual(engine.currentScreenId, "goal_q")
        XCTAssertTrue(engine.goBack())
        XCTAssertEqual(engine.currentScreenId, "welcome")
    }

    func testTerminalCompletes() throws {
        let engine = try FlowEngine(flow: buildBranchingFlow())
        try engine.advance() // → goal_q
        try engine.setVariable("goal", AnyHashable("lose"))
        try engine.advance() // → lose_path (finale, no transitions)
        let step = try engine.advance() // implicit completion
        if case .completed(let reason) = step {
            XCTAssertEqual(reason, "completed")
        } else { XCTFail("Expected completed") }
        XCTAssertTrue(engine.isComplete)
    }

    func testEndReasonSentinel() throws {
        let json = """
        {
          "schema_version": 1, "id": "t", "entry_screen_id": "a",
          "screens": [
            { "id": "a", "archetype": "welcome",
              "content": { "title": "X", "cta_label": "Skip" },
              "transitions": [{ "go": "end:skipped" }] }
          ]
        }
        """
        let flow = try Flow.decode(fromJSONString: json)
        let engine = try FlowEngine(flow: flow)
        let step = try engine.advance()
        if case .completed(let reason) = step { XCTAssertEqual(reason, "skipped") }
        else { XCTFail("Expected completed:skipped") }
    }
}
