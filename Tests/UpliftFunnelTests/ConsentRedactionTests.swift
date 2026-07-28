// Consent and redaction: what reaches the Uplift API, and what the host app
// still gets regardless.
//
// The line these tests hold is that redaction is an ANALYTICS boundary, not an
// engine one. The host keeps receiving every answer — it's their user's data
// and collecting it is the point of the funnel. Only the upload is trimmed.

import XCTest
@testable import UpliftFunnel

final class ConsentRedactionTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_700_000_000)

    private func uploader(redact: Set<String> = []) -> EventUploader {
        EventUploader(config: EventUploaderConfig(
            endpoint: URL(string: "https://example.com/v1/events")!,
            redactVariables: redact,
            apiKeyProvider: { "fnl_pk_test" }))
    }

    private func payload(
        _ event: FlowEvent, redacted: Set<String>, on uploader: EventUploader
    ) -> [String: JSONValue] {
        let wire = uploader.serialize(
            event, sessionId: "sess_1", flowId: "f", experiment: nil,
            flowVersion: nil, redacted: redacted)
        return wire["payload"]?.objectValue ?? [:]
    }

    // MARK: - Redaction

    func testSensitiveVariableReportsAnsweredNotTheAnswer() {
        let event = FlowEvent.variableSet(
            flowId: "f", timestamp: ts, screenId: "s",
            name: "email", value: .string("someone@example.com"))

        let out = payload(event, redacted: ["email"], on: uploader())

        XCTAssertEqual(out["redacted"]?.boolValue, true)
        XCTAssertNil(out["value"])
        XCTAssertEqual(out["name"]?.stringValue, "email")
    }

    func testBoundedAnswerKeepsItsValue() {
        let event = FlowEvent.variableSet(
            flowId: "f", timestamp: ts, screenId: "s",
            name: "goal", value: .string("lose_weight"))

        let out = payload(event, redacted: ["email"], on: uploader())

        XCTAssertEqual(out["value"]?.stringValue, "lose_weight")
        XCTAssertNil(out["redacted"])
    }

    func testCompletedListsRedactedNamesInsteadOfValues() {
        let event = FlowEvent.completed(
            flowId: "f", timestamp: ts, reason: "completed",
            variables: [
                "email": .string("someone@example.com"),
                "goal": .string("lose_weight"),
                "reminders": .bool(true),
            ])

        let out = payload(event, redacted: ["email"], on: uploader())
        let variables = out["variables"]?.objectValue ?? [:]

        XCTAssertNil(variables["email"])
        XCTAssertEqual(variables["goal"]?.stringValue, "lose_weight")
        // A placeholder inside `variables` would be indistinguishable from
        // `reminders`, which is genuinely true — so the names travel apart.
        XCTAssertEqual(variables["reminders"]?.boolValue, true)
        XCTAssertEqual(out["redacted"]?.arrayValue?.compactMap(\.stringValue), ["email"])
    }

    func testCompletedOmitsTheRedactedKeyWhenNothingIsHeld() {
        let event = FlowEvent.completed(
            flowId: "f", timestamp: ts, reason: "completed",
            variables: ["goal": .string("lose_weight")])

        XCTAssertNil(payload(event, redacted: [], on: uploader())["redacted"])
    }

    func testFlowVariablesParseTheSensitiveFlag() throws {
        let json = try JSONValue.parse(Data("""
        {"schema_version":1,"id":"f","entry_screen_id":"s",
         "variables":[
           {"name":"email","type":"string","sensitive":true},
           {"name":"goal","type":"string"}
         ],
         "screens":[{"id":"s","archetype":"welcome",
           "root":{"type":"stack","children":[]},"transitions":[]}]}
        """.utf8))
        let flow = try FunnelFlow(json: json)

        let byName = Dictionary(uniqueKeysWithValues: flow.variables.map { ($0.name, $0.sensitive) })
        XCTAssertEqual(byName["email"], true)
        XCTAssertEqual(byName["goal"], false)
    }

    // MARK: - Consent gate

    func testNothingIsQueuedWhileTrackingIsOff() async {
        let uploader = uploader()
        await uploader.setTrackingEnabled(false)

        await uploader.enqueue(["event_type": .string("flow_started")])

        let count = await uploader.bufferedCount
        XCTAssertEqual(count, 0)
    }

    func testTurningItOffDropsWhatWasAlreadyQueued() async {
        let uploader = uploader()
        await uploader.enqueue(["event_type": .string("variable_set")])
        let before = await uploader.bufferedCount
        XCTAssertEqual(before, 1)

        await uploader.setTrackingEnabled(false)

        let after = await uploader.bufferedCount
        XCTAssertEqual(after, 0)
    }

    func testTurningItBackOnStartsCleanRatherThanReplaying() async {
        let uploader = uploader()
        await uploader.enqueue(["event_type": .string("variable_set")])
        await uploader.setTrackingEnabled(false)
        await uploader.setTrackingEnabled(true)

        // The pre-revoke event is gone for good; only what comes after counts.
        let afterRevoke = await uploader.bufferedCount
        XCTAssertEqual(afterRevoke, 0)

        await uploader.enqueue(["event_type": .string("flow_completed")])
        let afterConsent = await uploader.bufferedCount
        XCTAssertEqual(afterConsent, 1)
    }
}
