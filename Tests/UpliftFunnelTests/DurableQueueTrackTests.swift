import XCTest
@testable import UpliftFunnel

final class DurableQueueTrackTests: XCTestCase {
    private let endpoint = URL(string: "https://api.example.com/v1/events")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func makeUploader(
        store: EventQueueStore, flushEvery: TimeInterval = 60
    ) -> EventUploader {
        var config = EventUploaderConfig(
            endpoint: endpoint, apiKeyProvider: { "fnl_pk_test" })
        config.flushEvery = flushEvery
        config.queueStore = store
        config.urlSession = MockURLProtocol.session()
        return EventUploader(config: config)
    }

    func testEnqueuePersistsDebounced() async throws {
        let store = InMemoryEventQueueStore()
        let uploader = makeUploader(store: store)
        await uploader.enqueueCustom(name: "signup_done", sessionId: "sess_1")
        // 500 ms debounce, then the buffer lands in the store.
        let persisted = await waitUntil(timeout: 3) { !store.events.isEmpty }
        XCTAssertTrue(persisted)
        XCTAssertEqual(store.events.first?["event_type"]?.stringValue, "signup_done")
    }

    func testRestoreLoadsPersistedEventsAndFlushes() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
        let store = InMemoryEventQueueStore()
        store.save([
            ["event_id": "e_persisted00000001", "event_type": "app_open",
             "session_id": "sess_prev", "timestamp": 1721400000000]
        ])
        let uploader = makeUploader(store: store, flushEvery: 0.05)
        await uploader.restore()
        let posted = await waitUntil { !MockURLProtocol.recorded.isEmpty }
        XCTAssertTrue(posted)
        let events = MockURLProtocol.recorded[0].bodyJSON?["events"].arrayValue
        XCTAssertEqual(events?[0]["event_id"].stringValue, "e_persisted00000001")
        // Successful flush clears the durable store.
        let cleared = await waitUntil { store.events.isEmpty }
        XCTAssertTrue(cleared)
    }

    func testByteCapTrimsOldestWhenStoreConfigured() async throws {
        let store = InMemoryEventQueueStore()
        var config = EventUploaderConfig(
            endpoint: endpoint, apiKeyProvider: { "k" })
        config.flushEvery = 60
        config.flushAt = 10_000
        config.maxBufferBytes = 400
        config.queueStore = store
        config.urlSession = MockURLProtocol.session()
        let uploader = EventUploader(config: config)
        for i in 0..<10 {
            await uploader.enqueue([
                "event_type": .string("evt_\(i)"), "session_id": "s",
                "payload": .object(["filler": .string(String(repeating: "x", count: 60))]),
            ])
        }
        let buffered = await uploader.bufferedEvents
        XCTAssertLessThan(buffered.count, 10, "byte cap should trim")
        XCTAssertEqual(buffered.last?["event_type"], "evt_9", "newest survives")
    }

    func testEnqueueCustomOmitsFlowIdWhenNil() async throws {
        let uploader = makeUploader(store: InMemoryEventQueueStore())
        await uploader.enqueueCustom(
            name: "app_level", sessionId: "sess_app",
            properties: ["k": "v"])
        let buffered = await uploader.bufferedEvents
        XCTAssertNil(buffered[0]["flow_id"])
        XCTAssertEqual(buffered[0]["event_type"], "app_level")
        XCTAssertEqual(buffered[0]["payload"]?["k"], "v")

        await uploader.enqueueCustom(
            name: "in_flow", sessionId: "sess_flow", flowId: "demo")
        let second = await uploader.bufferedEvents
        XCTAssertEqual(second[1]["flow_id"], "demo")
    }

    func testUserDefaultsStoreRoundTripAndCorruptionTolerance() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = UserDefaultsEventQueueStore(defaults: defaults)
        XCTAssertEqual(store.load().count, 0)

        store.save([["event_type": "a", "session_id": "s"]])
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load()[0]["event_type"], "a")

        // Corrupt entry — dropped rather than crashing on next launch.
        defaults.set("{not json", forKey: "funnel.event_queue.v1")
        XCTAssertEqual(store.load().count, 0)

        store.clear()
        XCTAssertNil(defaults.string(forKey: "funnel.event_queue.v1"))
    }
}
