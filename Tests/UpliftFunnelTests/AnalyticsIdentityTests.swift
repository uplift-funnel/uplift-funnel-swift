import XCTest
@testable import UpliftFunnel

@MainActor
final class AnalyticsIdentityTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
    }

    override func tearDown() {
        UpliftFunnel.resetForTests()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func configure(apiKey: String = "fnl_pk_test") async {
        await UpliftFunnel.configureInternal(
            apiKey: apiKey, serverUrl: "https://api.example.com",
            urlSession: MockURLProtocol.session(), defaults: defaults)
    }

    func testConfigureCreatesAndPersistsAnonymousId() async throws {
        await configure()
        let stored = defaults.string(forKey: "funnel.anonymous_subject_id")
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored!.hasPrefix("anon_"))
        XCTAssertEqual(stored!.count, "anon_".count + 32)

        // Reconfigure keeps the same id (sticky bucketing survives).
        await configure(apiKey: "fnl_pk_other")
        XCTAssertEqual(defaults.string(forKey: "funnel.anonymous_subject_id"), stored)
    }

    func testIdentifyPersistsAndPostsMapping() async throws {
        await configure()
        let anon = defaults.string(forKey: "funnel.anonymous_subject_id")!
        try await UpliftFunnel.identify(userId: "user_42", attributes: ["plan": "pro"])

        XCTAssertEqual(defaults.string(forKey: "funnel.identified_user_id"), "user_42")

        let posted = await waitUntil {
            MockURLProtocol.recorded.contains {
                $0.url?.path == "/v1/identify"
            }
        }
        XCTAssertTrue(posted)
        let identify = MockURLProtocol.recorded.first { $0.url?.path == "/v1/identify" }
        XCTAssertEqual(identify?.bodyJSON?["user_id"].stringValue, "user_42")
        XCTAssertEqual(identify?.bodyJSON?["anonymous_id"].stringValue, anon)
        XCTAssertEqual(identify?.header("Authorization"), "Bearer fnl_pk_test")
    }

    func testResetIdentityRotatesAnonymousId() async throws {
        await configure()
        try await UpliftFunnel.identify(userId: "user_42")
        let before = defaults.string(forKey: "funnel.anonymous_subject_id")!

        try await UpliftFunnel.resetIdentity()
        XCTAssertNil(defaults.string(forKey: "funnel.identified_user_id"))
        let after = defaults.string(forKey: "funnel.anonymous_subject_id")!
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.hasPrefix("anon_"))
    }

    func testIdentityRestoredFromDiskOnConfigure() async throws {
        defaults.set("user_restored", forKey: "funnel.identified_user_id")
        await configure()
        try await UpliftFunnel.track("app_open")
        await UpliftFunnel.flushEvents()
        let posted = await waitUntil {
            MockURLProtocol.recorded.contains { $0.url?.path == "/v1/events" }
        }
        XCTAssertTrue(posted)
        let events = MockURLProtocol.recorded
            .first { $0.url?.path == "/v1/events" }?
            .bodyJSON?["events"].arrayValue
        XCTAssertEqual(events?[0]["user_id"].stringValue, "user_restored")
    }

    func testSetAttributionFiltersTruncatesAndPersists() async throws {
        await configure()
        try await UpliftFunnel.setAttribution([
            "source": "meta",
            "campaign": String(repeating: "c", count: 300),
            "bogus_key": "nope",
            "creative": "",
        ])
        let raw = defaults.string(forKey: "funnel.attribution")
        let stored = try JSONValue.parse(try XCTUnwrap(raw))
        XCTAssertEqual(stored["source"].stringValue, "meta")
        XCTAssertEqual(stored["campaign"].stringValue?.count, 256)
        XCTAssertTrue(stored["bogus_key"].isNull)
        XCTAssertTrue(stored["creative"].isNull)

        // Attribution lands in event context on subsequent events.
        try await UpliftFunnel.track("app_open")
        await UpliftFunnel.flushEvents()
        _ = await waitUntil {
            MockURLProtocol.recorded.contains { $0.url?.path == "/v1/events" }
        }
        let body: JSONValue = MockURLProtocol.recorded
            .first { $0.url?.path == "/v1/events" }?.bodyJSON ?? .null
        let context = body["events"][0]["context"]
        XCTAssertEqual(context["source"].stringValue, "meta")
        XCTAssertEqual(context["platform"].stringValue, DeviceContext.platform)
        XCTAssertEqual(context["sdk_version"].stringValue, kUpliftFunnelSdkVersion)
    }

    func testTrackValidatesEventName() async throws {
        await configure()
        try await UpliftFunnel.track("valid_name:v2")
        for badName in ["Invalid-Name", "9starts_with_digit"] {
            do {
                try await UpliftFunnel.track(badName)
                XCTFail("expected throw for \(badName)")
            } catch UpliftFunnelError.invalidEventName {
                // expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTrackOutsideFlowUsesAppSessionId() async throws {
        await configure()
        try await UpliftFunnel.track("standalone")
        await UpliftFunnel.flushEvents()
        _ = await waitUntil {
            MockURLProtocol.recorded.contains { $0.url?.path == "/v1/events" }
        }
        let body: JSONValue = MockURLProtocol.recorded
            .first { $0.url?.path == "/v1/events" }?.bodyJSON ?? .null
        let event = body["events"][0]
        XCTAssertEqual(event["event_type"].stringValue, "standalone")
        XCTAssertTrue(event["session_id"].stringValue?.hasPrefix("sess_") ?? false)
        XCTAssertTrue(event["flow_id"].isNull, "no flow_id outside a flow")
        XCTAssertTrue(event["anonymous_id"].stringValue?.hasPrefix("anon_") ?? false)
    }
}
