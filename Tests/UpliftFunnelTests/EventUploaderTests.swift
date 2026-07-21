import XCTest
@testable import UpliftFunnel

final class EventUploaderTests: XCTestCase {
    private let endpoint = URL(string: "https://api.example.com/v1/events")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeUploader(
        apiKey: String = "fnl_pk_test",
        flushAt: Int = 20,
        store: EventQueueStore? = nil
    ) -> EventUploader {
        var config = EventUploaderConfig(
            endpoint: endpoint, apiKeyProvider: { apiKey })
        config.flushAt = flushAt
        config.flushEvery = 60  // effectively "manual flush only" in tests
        config.retryBackoffBase = 60
        config.userIdProvider = { "user_42" }
        config.anonymousIdProvider = { "anon_abc" }
        config.contextProvider = { ["platform": "ios", "sdk_version": "0.1.0"] }
        config.queueStore = store
        config.urlSession = MockURLProtocol.session()
        return EventUploader(config: config)
    }

    private func sampleEvent(_ type: String = "flow_started") -> [String: JSONValue] {
        ["event_id": .string(Identifiers.eventId()),
         "session_id": "sess_1", "flow_id": "demo",
         "event_type": .string(type), "timestamp": 1721400000000]
    }

    // MARK: Serialization

    @MainActor
    func testSerializeShapes() throws {
        let uploader = makeUploader()
        let experiment = UpliftFunnelExperimentAssignment(
            experimentId: "exp", variantId: "v1")
        let ts = Date(timeIntervalSince1970: 1721400000)

        let started = uploader.serialize(
            .started(flowId: "demo", timestamp: ts, entryScreenId: "welcome"),
            sessionId: "sess_1", flowId: "demo",
            experiment: experiment, flowVersion: 7)
        XCTAssertEqual(started["event_type"], "flow_started")
        XCTAssertEqual(started["screen_id"], "welcome")
        XCTAssertEqual(started["session_id"], "sess_1")
        XCTAssertEqual(started["flow_id"], "demo")
        XCTAssertEqual(started["timestamp"], 1721400000000)
        XCTAssertEqual(started["user_id"], "user_42")
        XCTAssertEqual(started["anonymous_id"], "anon_abc")
        XCTAssertEqual(started["flow_version"], 7)
        XCTAssertEqual(started["experiment_id"], "exp")
        XCTAssertEqual(started["variant_id"], "v1")
        XCTAssertEqual(started["context"]?["platform"], "ios")
        XCTAssertTrue(started["event_id"]?.stringValue?.hasPrefix("e_") ?? false)

        let changed = uploader.serialize(
            .screenChanged(flowId: "demo", timestamp: ts, from: "a", to: "b"),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(changed["event_type"], "screen_changed")
        XCTAssertEqual(changed["screen_id"], "b")
        XCTAssertEqual(changed["payload"]?["from"], "a")
        XCTAssertNil(changed["experiment_id"])
        XCTAssertNil(changed["flow_version"])

        let varSet = uploader.serialize(
            .variableSet(flowId: "demo", timestamp: ts, screenId: "q",
                         name: "goal", value: "lose"),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(varSet["event_type"], "variable_set")
        XCTAssertEqual(varSet["payload"]?["name"], "goal")
        XCTAssertEqual(varSet["payload"]?["value"], "lose")

        let purchase = uploader.serialize(
            .purchase(flowId: "demo", timestamp: ts, stage: "succeeded",
                      screenId: "paywall", planId: "yearly", productId: "com.x.y"),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(purchase["event_type"], "purchase_succeeded")
        XCTAssertEqual(purchase["payload"]?["plan_id"], "yearly")
        XCTAssertEqual(purchase["payload"]?["product_id"], "com.x.y")

        let completed = uploader.serialize(
            .completed(flowId: "demo", timestamp: ts, reason: "completed",
                       variables: ["goal": "lose"]),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(completed["event_type"], "flow_completed")
        XCTAssertEqual(completed["payload"]?["variables"]["goal"], "lose")

        let abandoned = uploader.serialize(
            .completed(flowId: "demo", timestamp: ts, reason: "abandoned",
                       variables: [:]),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(abandoned["event_type"], "flow_abandoned")
        XCTAssertEqual(abandoned["payload"]?["reason"], "abandoned")

        let custom = uploader.serialize(
            .custom(flowId: "demo", timestamp: ts, name: "url:https://x.com",
                    variables: [:]),
            sessionId: "s", flowId: "demo", experiment: nil, flowVersion: nil)
        XCTAssertEqual(custom["event_type"], "custom_event")
        XCTAssertEqual(custom["payload"]?["name"], "url:https://x.com")
    }

    // MARK: Flush behavior

    func testFlushAtThresholdPostsBatch() async throws {
        MockURLProtocol.handler = { _ in
            .stub(.init(statusCode: 200, json: #"{"inserted":2,"duplicates":0}"#))
        }
        let uploader = makeUploader(flushAt: 2)
        await uploader.enqueue(sampleEvent())
        await uploader.enqueue(sampleEvent("screen_changed"))

        let posted = await waitUntil { !MockURLProtocol.recorded.isEmpty }
        XCTAssertTrue(posted)

        let recorded = MockURLProtocol.recorded[0]
        XCTAssertEqual(recorded.header("Authorization"), "Bearer fnl_pk_test")
        XCTAssertEqual(recorded.header("Content-Type"), "application/json")
        let events = recorded.bodyJSON?["events"].arrayValue
        XCTAssertEqual(events?.count, 2)
        XCTAssertEqual(events?[0]["event_type"].stringValue, "flow_started")
        let empty = await uploader.bufferedEventCount
        XCTAssertEqual(empty, 0)
    }

    func testManualFlushDrainsBuffer() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
        let uploader = makeUploader()
        await uploader.enqueue(sampleEvent())
        await uploader.flushNow()
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
        let count = await uploader.bufferedEventCount
        XCTAssertEqual(count, 0)
    }

    func test4xxDropsBatch() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 400, json: "{}")) }
        let uploader = makeUploader()
        await uploader.enqueue(sampleEvent())
        await uploader.flushNow()
        let count = await uploader.bufferedEventCount
        XCTAssertEqual(count, 0, "4xx must drop, not retry")
    }

    func test5xxRequeuesWithStableEventIds() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 503, json: "{}")) }
        let uploader = makeUploader()
        let event = sampleEvent()
        await uploader.enqueue(event)
        await uploader.flushNow()
        // Requeued to the front, same event_id for server-side dedup.
        let buffered = await uploader.bufferedEvents
        XCTAssertEqual(buffered.count, 1)
        XCTAssertEqual(buffered[0]["event_id"], event["event_id"])

        // Retry succeeds and reuses the identical id on the wire.
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
        await uploader.flushNow()
        let secondBody = MockURLProtocol.recorded.last?.bodyJSON
        XCTAssertEqual(
            secondBody?["events"][0]["event_id"], event["event_id"] ?? .null)
        let count = await uploader.bufferedEventCount
        XCTAssertEqual(count, 0)
    }

    func testTransportErrorRequeues() async throws {
        MockURLProtocol.handler = { _ in .error(URLError(.timedOut)) }
        let uploader = makeUploader()
        await uploader.enqueue(sampleEvent())
        await uploader.flushNow()
        let count = await uploader.bufferedEventCount
        XCTAssertEqual(count, 1)
    }

    func testEmptyApiKeyDropsClientSide() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
        let uploader = makeUploader(apiKey: "")
        await uploader.enqueue(sampleEvent())
        await uploader.flushNow()
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty, "no POST without a key")
        let count = await uploader.bufferedEventCount
        XCTAssertEqual(count, 0)
    }

    func testMaxBufferDropsOldest() async throws {
        var config = EventUploaderConfig(
            endpoint: endpoint, apiKeyProvider: { "k" })
        config.flushEvery = 60
        config.flushAt = 10_000
        config.maxBuffer = 3
        config.urlSession = MockURLProtocol.session()
        let uploader = EventUploader(config: config)
        for i in 0..<5 {
            await uploader.enqueue(["event_type": .string("e\(i)"), "session_id": "s"])
        }
        let buffered = await uploader.bufferedEvents
        XCTAssertEqual(buffered.count, 3)
        XCTAssertEqual(buffered.first?["event_type"], "e2")
    }
}
