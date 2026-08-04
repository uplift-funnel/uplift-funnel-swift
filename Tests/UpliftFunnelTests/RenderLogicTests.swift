import XCTest
@testable import UpliftFunnel

// Render-logic tests that need no UI: the purchase dispatch/analytics contract
// and the variable round-trip between the session and the renderer.
//
// The choice, enabled_when, plan-layout and pinned-extraction suites that used
// to live here went with the v2 renderer. Their subjects were v2 concepts —
// `ChoiceSelection`, `plan_picker`, and a pinned CTA lifted out of the tree by
// hand. v3 expresses all three differently and asserts them elsewhere:
// multi-select semantics in `InteractionTests`, and pinning in the SOLVER,
// where `self.position: fixed` is checked against Chromium's own frames rather
// than against a tree-surgery helper.

// MARK: - Purchase flow

@MainActor
final class PurchaseFlowTests: XCTestCase {
    private func makeSession() throws -> FlowSession {
        try FlowSession(flow: try FunnelFlow(json: try JSONValue.parse("""
        {"schema_version":1,"id":"paywall-flow","entry_screen_id":"paywall",
         "screens":[
           {"id":"paywall","archetype":"plan_picker",
            "transitions":[{"go":"end:completed"}]}
         ]}
        """)))
    }

    private func purchaseStages(_ session: FlowSession) -> Box<[String]> {
        let box = Box<[String]>([])
        session.addEventListener { event in
            if case .purchase(_, _, let stage, _, _, _, _, _) = event {
                box.value.append(stage)
            }
        }
        return box
    }

    func testSuccessfulPurchaseTracksAndAdvances() async throws {
        let session = try makeSession()
        let stages = purchaseStages(session)
        let plan: JSONValue = ["id": "yearly", "product_id_ios": "com.x.ios"]

        let ok = await performPurchaseBridge(
            session: session, screenId: "paywall", plan: plan, planId: "yearly",
            handler: { request in
                XCTAssertEqual(request.planId, "yearly")
                XCTAssertEqual(request.productId, "com.x.ios")
                XCTAssertEqual(request.flowId, "paywall-flow")
                XCTAssertEqual(request.screenId, "paywall")
                return .purchased
            })
        XCTAssertTrue(ok)
        XCTAssertEqual(stages.value, ["attempted", "succeeded"])
    }

    func testCancelledAndFailedAndPendingDoNotAdvance() async throws {
        for (result, stage) in [
            (PurchaseResult.cancelled, "cancelled"),
            (.failed, "failed"),
            (.pending, "pending"),
        ] {
            let session = try makeSession()
            let stages = purchaseStages(session)
            let ok = await performPurchaseBridge(
                session: session, screenId: "paywall", plan: nil, planId: nil,
                handler: { _ in result })
            XCTAssertFalse(ok)
            XCTAssertEqual(stages.value, ["attempted", stage])
        }
    }

    func testStringifyAndDecodeVariablesRoundTrip() {
        let vars: [String: JSONValue] = [
            "goal": "lose",
            "age": 25,
            "flag": true,
            "areas": ["sleep", "stress"],
        ]
        let strings = stringifyVariables(vars)
        XCTAssertEqual(strings["goal"], "lose")
        XCTAssertEqual(strings["age"], "25")
        XCTAssertEqual(strings["flag"], "true")
        XCTAssertEqual(strings["areas"], #"["sleep","stress"]"#)

        // Renderer writes decode back: arrays become real arrays.
        XCTAssertEqual(decodeValue(#"["a","b"]"#), ["a", "b"])
        XCTAssertEqual(decodeValue("scalar"), "scalar")
        XCTAssertEqual(decodeValue("[not json"), "[not json")
    }
}

/// Reference box for collecting values from escaping closures in tests.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
