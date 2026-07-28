import XCTest
@testable import UpliftFunnel

@MainActor
final class UpliftFunnelFacadeTests: XCTestCase {
    private var defaults: UserDefaults!

    private let flowJson = """
    {"schema_version":1,"id":"demo","entry_screen_id":"welcome",
     "screens":[
       {"id":"welcome","archetype":"welcome",
        "root":{"type":"stack","children":[{"type":"text","props":{"value":"Hi"}}]},
        "transitions":[{"go":"end:completed"}]}
     ]}
    """

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")
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

    func testNotConfiguredThrowsTyped() async {
        do {
            _ = try await UpliftFunnel.start("demo")
            XCTFail("expected throw")
        } catch let error as UpliftFunnelError {
            guard case .notConfigured(let method) = error else {
                return XCTFail("wrong case")
            }
            XCTAssertEqual(method, "start")
        } catch {
            XCTFail("unexpected \(error)")
        }
        do {
            try await UpliftFunnel.track("x")
            XCTFail("expected throw")
        } catch {}
        XCTAssertFalse(UpliftFunnel.isConfigured)
    }

    func testStartEndToEndUploadsFlowEvents() async throws {
        MockURLProtocol.handler = { [flowJson] request in
            if request.url?.path.hasPrefix("/v1/flows/") == true {
                return .stub(.init(
                    statusCode: 200,
                    headers: ["ETag": "\"e1\"", "X-Uplift-Flow-Version": "5"],
                    json: flowJson))
            }
            return .stub(.init(statusCode: 200, json: #"{"inserted":1,"duplicates":0}"#))
        }
        await configure()
        let start = try await UpliftFunnel.start("demo")
        XCTAssertEqual(start.source, .network)
        XCTAssertEqual(start.flowVersion, 5)
        XCTAssertEqual(start.session.currentScreen.id, "welcome")
        XCTAssertNil(start.experiment)

        // Walk to completion, then force a drain and assert the wire shape.
        start.session.advance()
        XCTAssertTrue(start.session.completed)
        // The deferred flow_started event needs a main-actor hop.
        try await Task.sleep(nanoseconds: 50_000_000)
        await UpliftFunnel.flushEvents()

        let posted = await waitUntil {
            MockURLProtocol.recorded.contains { $0.url?.path == "/v1/events" }
        }
        XCTAssertTrue(posted)
        let events = MockURLProtocol.recorded
            .first { $0.url?.path == "/v1/events" }?
            .bodyJSON?["events"].arrayValue ?? []
        let types = Set(events.compactMap { $0["event_type"].stringValue })
        XCTAssertTrue(types.contains("flow_completed"), "got \(types)")
        for event in events {
            XCTAssertEqual(event["flow_id"].stringValue, "demo")
            XCTAssertEqual(event["flow_version"].intValue, 5)
            XCTAssertEqual(event["session_id"].stringValue, start.session.sessionId)
        }
    }

    func testConfigureIdempotenceKeepsHandlersAndProducts() async throws {
        await configure()
        let box = AssignmentBox()  // reuse as a flag box
        UpliftFunnel.registerLinkHandler { _ in
            box.value = UpliftFunnelExperimentAssignment(experimentId: "hit", variantId: "x")
        }
        UpliftFunnel.setProducts([UpliftFunnelProduct(id: "p", price: "$1")])

        await configure(apiKey: "fnl_pk_second")
        XCTAssertEqual(UpliftFunnel.lookupProducts()["p"]?.price, "$1")

        XCTAssertTrue(UpliftFunnel.openLink("https://x"))
        XCTAssertEqual(box.value?.experimentId, "hit")
    }

    func testStartExperimentSurfacesAndPersistsAssignment() async throws {
        MockURLProtocol.handler = { [flowJson] request in
            if request.url?.path.hasPrefix("/v1/experiments/") == true {
                return .stub(.init(
                    statusCode: 200,
                    headers: [
                        "X-Uplift-Experiment": "exp_9:var_b",
                        "X-Uplift-Variant-Name": "Bold%20CTA",
                        "ETag": "\"x1\"",
                    ],
                    json: flowJson))
            }
            return .stub(.init(statusCode: 200, json: "{}"))
        }
        await configure()
        let start = try await UpliftFunnel.startExperiment("exp-key")
        XCTAssertEqual(start.experiment?.experimentId, "exp_9")
        XCTAssertEqual(start.experiment?.variantId, "var_b")
        XCTAssertEqual(start.experiment?.variantName, "Bold CTA")
        XCTAssertEqual(UpliftFunnel.lastExperiment, start.experiment)

        // Subject header was attached (anonymous — no identify yet).
        let request = MockURLProtocol.recorded.first {
            $0.url?.path.hasPrefix("/v1/experiments/") == true
        }
        XCTAssertTrue(
            request?.header("X-Uplift-Subject-Id")?.hasPrefix("anon_") ?? false)

        // Persisted for warm-cache starts.
        let persisted = defaults.string(
            forKey: "funnel.experiment.exp-key.assignment")
        XCTAssertNotNil(persisted)

        // Warm-cache start (instant cache hit) falls back to the persisted
        // assignment even though no header is seen on the fast path.
        let warm = try await UpliftFunnel.startExperiment("exp-key")
        XCTAssertEqual(warm.source, .cache)
        XCTAssertEqual(warm.experiment?.variantId, "var_b")
        XCTAssertEqual(warm.experiment?.variantName, "Bold CTA")
    }

    func testStartPropagatesTypedFetchErrors() async throws {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 404, json: "nope")) }
        await configure()
        do {
            _ = try await UpliftFunnel.start("ghost")
            XCTFail("expected throw")
        } catch let error as FlowFetchError {
            XCTAssertEqual(error.kind, .notFound)
            XCTAssertEqual(error.flowKey, "ghost")
        }
    }

    func testStartRejectsMalformedFlowPayload() async throws {
        // Valid JSON, but not a valid flow document.
        MockURLProtocol.handler = { _ in
            .stub(.init(statusCode: 200, json: #"{"hello": "world"}"#))
        }
        await configure()
        do {
            _ = try await UpliftFunnel.start("weird")
            XCTFail("expected throw")
        } catch is FlowParseError {
            // expected
        }
    }

    func testProductVariablesReachSessionInterpolationScope() async throws {
        MockURLProtocol.handler = { [flowJson] _ in
            .stub(.init(statusCode: 200, json: flowJson))
        }
        await configure()
        UpliftFunnel.setProducts([
            UpliftFunnelProduct(id: "yearly_pro", price: "₺899,99")
        ])
        let start = try await UpliftFunnel.start(
            "demo", userVariables: ["greeting": "selam"])
        XCTAssertEqual(start.session.variables["price.yearly_pro"], "₺899,99")
        XCTAssertEqual(start.session.variables["greeting"], "selam")
    }
}
