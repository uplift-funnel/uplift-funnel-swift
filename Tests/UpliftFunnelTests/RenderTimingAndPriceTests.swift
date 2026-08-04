// Two new signals on the wire: how long a screen took, and what a purchase
// cost.
//
// Both are additive and both have a boundary that matters more than the field
// itself. `render_time` is a payload the metric registry reads, so `phase` and
// `ms` have to keep their spelling. And price rides only on the stage where
// money actually moved — a column that mixes intentions with sales is worse
// than not having one, because it sums.

import XCTest
@testable import UpliftFunnel

@MainActor
final class RenderTimingTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_700_000_000)

    private func uploader() -> EventUploader {
        EventUploader(config: EventUploaderConfig(
            endpoint: URL(string: "https://example.com/v1/events")!,
            apiKeyProvider: { "fnl_pk_test" }))
    }

    private func wire(_ event: FlowEvent) -> [String: JSONValue] {
        uploader().serialize(
            event, sessionId: "sess_1", flowId: "f", experiment: nil,
            flowVersion: nil)
    }

    private func session() throws -> FlowSession {
        try FlowSession(flow: try FunnelFlow(json: try JSONValue.parse("""
        {"schema_version":1,"id":"demo","entry_screen_id":"welcome",
         "screens":[
           {"id":"welcome","archetype":"welcome",
            "transitions":[{"go":"end:completed"}]}
         ]}
        """)))
    }

    func testRenderTimeIsAFirstClassEventType() {
        let out = wire(.renderTime(
            flowId: "f", timestamp: ts, screenId: "welcome",
            ms: 42, phase: "first_paint"))

        // A first-class type, not a `custom_event` with a discriminator in the
        // payload — server-side queries hit the (app_id, flow_id, event_type)
        // index directly.
        XCTAssertEqual(out["event_type"]?.stringValue, "render_time")
        XCTAssertEqual(out["screen_id"]?.stringValue, "welcome")
        let payload = try? XCTUnwrap(out["payload"]?.objectValue)
        XCTAssertEqual(payload?["ms"]?.doubleValue, 42)
        XCTAssertEqual(payload?["phase"]?.stringValue, "first_paint")
        XCTAssertEqual(
            payload?["screen_id"]?.stringValue, "welcome",
            "repeated in the payload the metric registry reads")
    }

    func testBothPhasesAreReportable() throws {
        let session = try session()
        let box = Box<[String]>([])
        session.addEventListener { event in
            if case .renderTime(_, _, _, _, let phase) = event {
                box.value.append(phase)
            }
        }

        session.trackRenderTime(screenId: "welcome", ms: 12, phase: "first_paint")
        session.trackRenderTime(screenId: "welcome", ms: 130, phase: "interactive")

        XCTAssertEqual(box.value, ["first_paint", "interactive"])
    }

    func testTimingCarriesTheScreenItMeasured() throws {
        let session = try session()
        let box = Box<[String]>([])
        session.addEventListener { event in
            if case .renderTime(_, _, let screenId, _, _) = event {
                box.value.append(screenId)
            }
        }

        // Per screen, not per session: "which screen is slow" is the question,
        // and a session average hides exactly the one that is.
        session.trackRenderTime(screenId: "welcome", ms: 12, phase: "first_paint")
        XCTAssertEqual(box.value, ["welcome"])
    }
}

@MainActor
final class PurchasePriceTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_700_000_000)

    private func wire(_ event: FlowEvent) -> [String: JSONValue] {
        EventUploader(config: EventUploaderConfig(
            endpoint: URL(string: "https://example.com/v1/events")!,
            apiKeyProvider: { "fnl_pk_test" })
        ).serialize(
            event, sessionId: "sess_1", flowId: "f", experiment: nil,
            flowVersion: nil)
    }

    private func purchase(
        stage: String, priceAmount: Double?, currencyCode: String?
    ) -> FlowEvent {
        .purchase(
            flowId: "f", timestamp: ts, stage: stage, screenId: "paywall",
            planId: "yearly", productId: "com.x.yearly",
            priceAmount: priceAmount, currencyCode: currencyCode)
    }

    func testSucceededCarriesThePrice() {
        let payload = wire(purchase(
            stage: "succeeded", priceAmount: 49.99, currencyCode: "USD")
        )["payload"]?.objectValue

        XCTAssertEqual(payload?["price_amount"]?.doubleValue, 49.99)
        XCTAssertEqual(payload?["currency_code"]?.stringValue, "USD")
        XCTAssertEqual(payload?["product_id"]?.stringValue, "com.x.yearly")
    }

    func testAttemptedDoesNotCarryThePrice() {
        let payload = wire(purchase(
            stage: "attempted", priceAmount: 49.99, currencyCode: "USD")
        )["payload"]?.objectValue

        // An attempt describes an intention. Summing a column that mixes
        // intentions with sales gives a revenue number nobody can defend.
        XCTAssertNil(payload?["price_amount"])
        XCTAssertNil(payload?["currency_code"])
        XCTAssertEqual(payload?["product_id"]?.stringValue, "com.x.yearly")
    }

    func testAnUnknownProductSendsNoPriceAtAll() {
        let payload = wire(purchase(
            stage: "succeeded", priceAmount: nil, currencyCode: nil)
        )["payload"]?.objectValue

        // The SDK never asks the store; if the host did not publish the
        // product through `setProducts`, the honest answer to "what did this
        // cost" is nothing rather than a guess.
        XCTAssertNil(payload?["price_amount"])
        XCTAssertNil(payload?["currency_code"])
    }

    func testTheBridgeReadsThePriceTheHostPublished() async throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { UpliftFunnel.resetForTests() }
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            defaults: defaults)
        UpliftFunnel.setProducts([
            UpliftFunnelProduct(
                id: "com.x.ios", price: "$49.99",
                priceAmount: 49.99, currencyCode: "USD")
        ])

        let session = try FlowSession(flow: try FunnelFlow(json: try JSONValue.parse("""
        {"schema_version":1,"id":"paywall-flow","entry_screen_id":"paywall",
         "screens":[
           {"id":"paywall","archetype":"plan_picker",
            "transitions":[{"go":"end:completed"}]}
         ]}
        """)))
        let prices = Box<[Double?]>([])
        session.addEventListener { event in
            if case .purchase(_, _, _, _, _, _, let amount, _) = event {
                prices.value.append(amount)
            }
        }

        _ = await performPurchaseBridge(
            session: session, screenId: "paywall",
            plan: ["id": "yearly", "product_id_ios": "com.x.ios"],
            planId: "yearly", handler: { _ in .purchased })

        // Resolved from the store catalog the host published — not from the
        // plan JSON's display price, which is copy an author typed months ago.
        XCTAssertEqual(prices.value, [49.99, 49.99])
    }
}
