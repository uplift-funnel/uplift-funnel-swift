import XCTest
@testable import UpliftFunnel

final class ModelsTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue.parse(try Data(contentsOf: url))
    }

    func testParsesPrimitiveSliceFixture() throws {
        let flow = try FunnelFlow(json: try fixture("primitive-slice"))
        XCTAssertEqual(flow.schemaVersion, 1)
        XCTAssertFalse(flow.screens.isEmpty)
        XCTAssertNotNil(flow.screen(byId: flow.entryScreenId))
        for screen in flow.screens {
            XCTAssertNotNil(screen.root.objectValue)
        }
    }

    func testParsesPrimitiveCatalogFixture() throws {
        let flow = try FunnelFlow(json: try fixture("primitive-catalog"))
        let prim = PrimFlow(json: flow.raw)
        XCTAssertEqual(prim.screens.count, flow.screens.count)
        // Every catalog screen carries a parsed root tree.
        for screen in prim.screens {
            XCTAssertNotNil(screen.root, "screen \(screen.id) lost its root")
        }
    }

    func testPrimNodeForgivingParsing() throws {
        let node = PrimNode(json: try JSONValue.parse("""
        {"props": {"x": 1}, "children": [
          {"type": "text", "props": {"value": "hi"}},
          "garbage",
          {"style": {"padding": 8}}
        ]}
        """))
        XCTAssertEqual(node.type, "unknown")
        XCTAssertEqual(node.props["x"].intValue, 1)
        // Non-object children are dropped; missing type -> unknown.
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children[0].type, "text")
        XCTAssertEqual(node.children[1].type, "unknown")
        XCTAssertEqual(node.children[1].style["padding"].intValue, 8)
    }

    func testTransitionTerminalParsing() throws {
        let t = try FunnelTransition(json: try JSONValue.parse(#"{"go": "end:skipped"}"#))
        XCTAssertTrue(t.isTerminal)
        XCTAssertTrue(t.isDefault)
        XCTAssertEqual(t.terminalReason, "skipped")

        let plain = try FunnelTransition(json: try JSONValue.parse(#"{"go": "next_screen"}"#))
        XCTAssertFalse(plain.isTerminal)
        XCTAssertNil(plain.terminalReason)
    }

    func testScreenToleratesMissingRoot() throws {
        let screen = try FunnelScreen(json: try JSONValue.parse(
            #"{"id": "s", "transitions": []}"#))
        XCTAssertEqual(screen.root, .object([:]))
        XCTAssertEqual(screen.archetypeRaw, "")
    }

    func testFlowParseErrorsOnMissingRequiredFields() {
        XCTAssertThrowsError(try FunnelFlow(json: ["id": "x"]))
        XCTAssertThrowsError(try FunnelFlow(json: [
            "schema_version": 1, "id": "x", "entry_screen_id": "a",
        ]))  // missing screens
    }

    func testPlanProductIdPlatformOverride() {
        let plan: JSONValue = [
            "id": "yearly", "product_id": "generic",
            "product_id_ios": "ios_yearly", "product_id_android": "droid_yearly",
        ]
        XCTAssertEqual(planProductId(plan, platform: "ios"), "ios_yearly")
        // macOS counts as iOS — same App Store catalog.
        XCTAssertEqual(planProductId(plan, platform: "macos"), "ios_yearly")
        XCTAssertEqual(planProductId(plan, platform: "android"), "droid_yearly")
        XCTAssertEqual(planProductId(["product_id": "generic"], platform: "ios"), "generic")
        XCTAssertNil(planProductId(["id": "p"], platform: "ios"))
        XCTAssertNil(planProductId(["product_id": ""], platform: "ios"))
    }

    func testExperimentAssignmentHeaderParsing() {
        let a = UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: "exp_1:var_b",
            variantNameHeader: "Blue%20CTA%20%E2%80%94%20v2")
        XCTAssertEqual(a?.experimentId, "exp_1")
        XCTAssertEqual(a?.variantId, "var_b")
        XCTAssertEqual(a?.variantName, "Blue CTA — v2")

        // Malformed headers mean "no assignment", never a crash.
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: nil, variantNameHeader: nil))
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: "", variantNameHeader: nil))
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: "no-colon", variantNameHeader: nil))
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: ":v", variantNameHeader: nil))
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: "e:", variantNameHeader: nil))
    }

    func testExperimentAssignmentJSONRoundTrip() {
        let a = UpliftFunnelExperimentAssignment(
            experimentId: "exp", variantId: "v1", variantName: "Ünlü — test")
        XCTAssertEqual(UpliftFunnelExperimentAssignment.fromJSON(a.toJSON()), a)
        XCTAssertNil(UpliftFunnelExperimentAssignment.fromJSON(["experiment_id": "e"]))
    }
}
