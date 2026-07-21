import XCTest
@testable import UpliftFunnel

// Behavioral render-logic tests that don't need UI: choice multi-select
// semantics, enabled_when gating, plan parsing, pinned-CTA extraction, and
// the purchase dispatch/analytics contract.

@MainActor
private func makeCtx(
    vars: [String: String] = [:],
    selections: [String: String] = [:],
    theme: JSONValue = .null
) -> RenderCtx {
    var ctx = RenderCtx(
        theme: PrimTheme(json: theme),
        locale: "en", defaultLocale: "en",
        localizations: .object([:]), vars: vars)
    ctx.selections = selections
    return ctx
}

// MARK: - Choice

@MainActor
final class ChoiceLogicTests: XCTestCase {
    func testSingleSelection() throws {
        let node = PrimNode(json: try JSONValue.parse(
            #"{"type":"choice","bind":{"save_to":"goal"}}"#))
        let ctx = makeCtx(selections: ["goal": "lose"])
        XCTAssertTrue(ChoiceSelection(node, ctx).contains("lose"))
        XCTAssertFalse(ChoiceSelection(node, ctx).contains("gain"))
    }

    func testMultiSelectionReadsJSONArray() throws {
        let node = PrimNode(json: try JSONValue.parse(
            #"{"type":"choice","props":{"mode":"multi"},"bind":{"save_to":"areas"}}"#))
        let ctx = makeCtx(selections: ["areas": #"["sleep","stress"]"#])
        let sel = ChoiceSelection(node, ctx)
        XCTAssertTrue(sel.contains("sleep"))
        XCTAssertTrue(sel.contains("stress"))
        XCTAssertFalse(sel.contains("focus"))
    }

    func testNextValueTogglesMembership() {
        XCTAssertEqual(
            ChoiceSelection.nextValue(current: [], toggling: "a", max: nil),
            #"["a"]"#)
        XCTAssertEqual(
            ChoiceSelection.nextValue(current: ["a"], toggling: "b", max: nil),
            #"["a","b"]"#)
        // Toggling off removes.
        XCTAssertEqual(
            ChoiceSelection.nextValue(current: ["a", "b"], toggling: "a", max: nil),
            #"["b"]"#)
    }

    func testNextValueEnforcesMaxCap() {
        // At the cap, adding is a no-op (nil = don't write)...
        XCTAssertNil(
            ChoiceSelection.nextValue(current: ["a", "b"], toggling: "c", max: 2))
        // ...but removing is always allowed.
        XCTAssertEqual(
            ChoiceSelection.nextValue(current: ["a", "b"], toggling: "b", max: 2),
            #"["a"]"#)
    }

    func testBoundValuesDecoding() {
        let ctx = makeCtx(vars: [
            "multi": #"["a","b"]"#,
            "scalar": "hello",
            "bracket_scalar": "[not json",
        ])
        XCTAssertEqual(ctx.boundValues("multi"), ["a", "b"])
        XCTAssertEqual(ctx.boundValues("scalar"), ["hello"])
        XCTAssertEqual(ctx.boundValues("bracket_scalar"), ["[not json"])
        XCTAssertEqual(ctx.boundValues("missing"), [])
        XCTAssertEqual(ctx.boundValues(nil), [])
    }
}

// MARK: - enabled_when

@MainActor
final class EnabledWhenTests: XCTestCase {
    func testGatesOnIsSet() throws {
        let condition = try JSONValue.parse(#"{"var":"goal","op":"is_set"}"#)
        XCTAssertFalse(makeCtx().isEnabled(condition))
        XCTAssertTrue(makeCtx(vars: ["goal": "x"]).isEnabled(condition))
    }

    func testLiveSelectionsWinOverVars() throws {
        let condition = try JSONValue.parse(
            #"{"var":"goal","op":"==","value":"lose"}"#)
        let ctx = makeCtx(vars: ["goal": "gain"], selections: ["goal": "lose"])
        XCTAssertTrue(ctx.isEnabled(condition))
    }

    func testMalformedConditionEnables() throws {
        // Unknown op — an authoring mistake must not strand the user.
        XCTAssertTrue(makeCtx().isEnabled(
            try JSONValue.parse(#"{"var":"goal","op":"~~","value":1}"#)))
        // Non-comparable numeric op degrades to enabled.
        XCTAssertTrue(makeCtx(vars: ["age": "abc"]).isEnabled(
            try JSONValue.parse(#"{"var":"age","op":">","value":18}"#)))
        // Absent condition = enabled.
        XCTAssertTrue(makeCtx().isEnabled(.null))
    }
}

// MARK: - Plans

@MainActor
final class PlanLayoutsTests: XCTestCase {
    private let planJson: JSONValue = [
        "id": "yearly", "label": "Yearly", "price": "$59.99",
        "period": "/year", "badge": "best value", "highlighted": true,
        "product_id": "com.x.generic", "product_id_ios": "com.x.yearly.ios",
        "features": ["All workouts", "", "Offline mode"],
    ]

    func testPlanDataParsing() {
        let ctx = makeCtx()
        let plan = PlanData(planJson, ctx)
        XCTAssertEqual(plan.id, "yearly")
        XCTAssertEqual(plan.label, "Yearly")
        XCTAssertEqual(plan.price, "$59.99")
        XCTAssertEqual(plan.badge, "best value")
        XCTAssertTrue(plan.highlighted)
        // Empty feature strings are dropped.
        XCTAssertEqual(plan.features, ["All workouts", "Offline mode"])
    }

    func testPriceAutoBindsFromProductCatalogViaPlatformProductId() {
        // The runtime catalog var wins over the authored price, keyed by the
        // iOS product id override.
        let ctx = makeCtx(vars: [
            "price.com.x.yearly.ios": "₺899,99",
            "original_price.com.x.yearly.ios": "₺1.199,99",
        ])
        let plan = PlanData(planJson, ctx)
        XCTAssertEqual(plan.price, "₺899,99")
        XCTAssertEqual(plan.originalPrice, "₺1.199,99")
    }

    func testAuthoredPriceUsedWithoutCatalogEntry() {
        let plan = PlanData(planJson, makeCtx())
        XCTAssertEqual(plan.price, "$59.99")
        XCTAssertEqual(plan.originalPrice, "")
    }

    func testPlanArtCtxDarkOverridesNeutrals() {
        let base = makeCtx()
        let dark = planArtCtx(base, accent: "#BFFF00", dark: true)
        XCTAssertEqual(dark.theme.colors["text_primary"], "#ffffff")
        XCTAssertEqual(dark.theme.colors["surface"], "rgba(255,255,255,0.06)")
        // The accent recolors primary lookups.
        XCTAssertEqual(dark.primary, parseCssColor("#BFFF00"))
        // Base ctx untouched.
        XCTAssertNil(base.theme.colors["text_primary"])
    }

    func testFindPlanSaveToDepthFirst() throws {
        let root = PrimNode(json: try JSONValue.parse("""
        {"type":"stack","children":[
          {"type":"text"},
          {"type":"stack","children":[
            {"type":"plan_picker","bind":{"save_to":"plan"}}
          ]}
        ]}
        """))
        XCTAssertEqual(findPlanSaveTo(root), "plan")
        XCTAssertNil(findPlanSaveTo(PrimNode(json: ["type": "stack"])))
    }
}

// MARK: - Pinned extraction

final class PinnedExtractionTests: XCTestCase {
    func testExtractsPinnedButtonAndKeepsTree() throws {
        let root = PrimNode(json: try JSONValue.parse("""
        {"type":"stack","props":{"direction":"column"},"children":[
          {"type":"text","props":{"value":"Hi"}},
          {"type":"stack","children":[
            {"type":"button","props":{"label":"CTA","pin_bottom":true}}
          ]},
          {"type":"button","props":{"label":"Inline"}}
        ]}
        """))
        let (kept, pinned) = extractPinned(root)
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned[0].props["label"].stringValue, "CTA")
        // Tree keeps its shape minus the pinned node.
        XCTAssertEqual(kept?.children.count, 3)
        XCTAssertEqual(kept?.children[1].children.count, 0)
        XCTAssertEqual(kept?.children[2].props["label"].stringValue, "Inline")
    }

    func testUntouchedTreeReturnsSameStructure() throws {
        let root = PrimNode(json: try JSONValue.parse(
            #"{"type":"stack","children":[{"type":"text"}]}"#))
        let (kept, pinned) = extractPinned(root)
        XCTAssertTrue(pinned.isEmpty)
        XCTAssertEqual(kept?.children.count, 1)
    }

    func testCarouselSubtreesLeftIntact() throws {
        // A slide-local CTA can't meaningfully pin to the screen.
        let root = PrimNode(json: try JSONValue.parse("""
        {"type":"carousel","children":[
          {"type":"button","props":{"pin_bottom":true}}
        ]}
        """))
        let (kept, pinned) = extractPinned(root)
        XCTAssertTrue(pinned.isEmpty)
        XCTAssertEqual(kept?.children.count, 1)
    }

    func testRootPinnedButtonLeavesNoBody() throws {
        let root = PrimNode(json: try JSONValue.parse(
            #"{"type":"button","props":{"pin_bottom":true}}"#))
        let (kept, pinned) = extractPinned(root)
        XCTAssertNil(kept)
        XCTAssertEqual(pinned.count, 1)
    }
}

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
            if case .purchase(_, _, let stage, _, _, _) = event {
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

    func testDispatchActionPurchaseSemantics() async throws {
        // No handler ⇒ purchase just advances (paywall inert until wired).
        var ctx = RenderCtx(
            theme: PrimTheme(json: .null), locale: "en", defaultLocale: "en",
            localizations: .object([:]), vars: [:])
        let actions = Box<[String]>([])
        ctx.onAction = { actions.value.append($0) }
        await ctx.dispatchAction("purchase")
        XCTAssertEqual(actions.value, ["next"])

        // Handler false ⇒ no advance.
        actions.value = []
        ctx.onPurchase = { _ in false }
        await ctx.dispatchAction("purchase")
        XCTAssertEqual(actions.value, [])

        // Handler true ⇒ advance, and the selected plan id is passed.
        let planIds = Box<[String?]>([])
        ctx.planSaveTo = "plan"
        ctx.selections = ["plan": "yearly"]
        ctx.onPurchase = { planId in
            planIds.value.append(planId)
            return true
        }
        await ctx.dispatchAction("purchase")
        XCTAssertEqual(actions.value, ["next"])
        XCTAssertEqual(planIds.value, ["yearly"])
    }

    func testDispatchActionRestoreSemantics() async throws {
        var ctx = RenderCtx(
            theme: PrimTheme(json: .null), locale: "en", defaultLocale: "en",
            localizations: .object([:]), vars: [:])
        let actions = Box<[String]>([])
        ctx.onAction = { actions.value.append($0) }

        // No handler ⇒ restore no-ops (nothing restored, nothing to gate on).
        await ctx.dispatchAction("restore")
        XCTAssertEqual(actions.value, [])

        // Handler false ⇒ still no advance.
        ctx.onRestore = { false }
        await ctx.dispatchAction("restore")
        XCTAssertEqual(actions.value, [])

        // Handler true ⇒ advance.
        ctx.onRestore = { true }
        await ctx.dispatchAction("restore")
        XCTAssertEqual(actions.value, ["next"])
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
