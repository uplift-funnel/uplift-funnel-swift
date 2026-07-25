import XCTest
@testable import UpliftFunnel

// Port of the Flutter SDK's flow_fetcher_test.dart — the caching/ETag
// behavioral contract.

final class FlowFetcherTests: XCTestCase {
    private var cache: InMemoryFlowCache!
    private var fetcher: FlowFetcher!
    private let url = URL(string: "https://api.example.com/v1/flows/demo")!

    private let flowJson = #"{"schema_version":1,"id":"demo","screens":[]}"#
    private let updatedJson = #"{"schema_version":1,"id":"demo","screens":[],"v":2}"#

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        cache = InMemoryFlowCache()
        fetcher = FlowFetcher(cache: cache, urlSession: MockURLProtocol.session())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func stub(
        _ status: Int, headers: [String: String] = [:], json: String = ""
    ) {
        MockURLProtocol.handler = { _ in
            .stub(.init(statusCode: status, headers: headers, json: json))
        }
    }

    // MARK: Cold cache

    func testColdCacheFetchesFromNetworkAndWritesCache() async throws {
        stub(200, headers: ["ETag": "\"abc\"", "X-Uplift-Flow-Version": "7"],
             json: flowJson)
        let result = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "fnl_pk_x")
        XCTAssertEqual(result.source, .network)
        XCTAssertEqual(result.json, flowJson)
        XCTAssertEqual(result.etag, "\"abc\"")
        XCTAssertEqual(result.flowVersion, 7)

        let cached = cache.read(flowId: "demo")
        XCTAssertEqual(cached?.json, flowJson)
        XCTAssertEqual(cached?.etag, "\"abc\"")
        XCTAssertEqual(cached?.version, 7)

        let request = MockURLProtocol.requests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer fnl_pk_x")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testColdCacheNetworkErrorThrowsTypedError() async {
        MockURLProtocol.handler = { _ in .error(URLError(.notConnectedToInternet)) }
        do {
            _ = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
            XCTFail("expected throw")
        } catch let error as FlowFetchError {
            XCTAssertEqual(error.kind, .network)
            XCTAssertEqual(error.flowKey, "demo")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStatusCodeMapping() async {
        for (status, kind) in [
            (404, FlowFetchError.Kind.notFound),
            (401, .unauthorized),
            (403, .forbidden),
            (500, .server),
        ] {
            stub(status, json: "irrelevant html")
            do {
                _ = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
                XCTFail("expected throw for \(status)")
            } catch let error as FlowFetchError {
                XCTAssertEqual(error.kind, kind)
                XCTAssertEqual(error.statusCode, status)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testInvalidJSONBodyThrowsInvalidPayload() async {
        stub(200, json: "<html>not json</html>")
        do {
            _ = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
            XCTFail("expected throw")
        } catch let error as FlowFetchError {
            XCTAssertEqual(error.kind, .invalidPayload)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Warm cache

    private func seedCache(version: Int? = 3) {
        cache.write(CachedFlow(
            flowId: "demo", json: flowJson, fetchedAt: Date(),
            etag: "\"abc\"", version: version))
    }

    func testHotCacheReturnsInstantlyAndRevalidatesInBackground() async throws {
        seedCache()
        stub(200, headers: ["ETag": "\"def\"", "X-Uplift-Flow-Version": "8"],
             json: updatedJson)

        let result = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
        XCTAssertEqual(result.source, .cache)
        XCTAssertEqual(result.json, flowJson)
        XCTAssertEqual(result.flowVersion, 3)
        XCTAssertNil(result.experimentAssignment)

        // Background revalidation rewrites the cache for next launch.
        let updated = await waitUntil { [cache] in
            cache!.read(flowId: "demo")?.json == self.updatedJson
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(cache.read(flowId: "demo")?.etag, "\"def\"")
        XCTAssertEqual(cache.read(flowId: "demo")?.version, 8)

        // The conditional GET carried the cached ETag.
        let sawConditional = await waitUntil {
            MockURLProtocol.requests.contains {
                $0.value(forHTTPHeaderField: "If-None-Match") == "\"abc\""
            }
        }
        XCTAssertTrue(sawConditional)
    }

    func testHotCache304KeepsCachedBody() async throws {
        seedCache()
        stub(304)
        let result = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
        XCTAssertEqual(result.source, .cache)
        _ = await waitUntil { MockURLProtocol.requests.count >= 1 }
        // Give the background task a beat, then confirm cache untouched.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cache.read(flowId: "demo")?.json, flowJson)
        XCTAssertEqual(cache.read(flowId: "demo")?.version, 3)
    }

    func testBackground304RefreshesAdvancedVersionHeader() async throws {
        seedCache(version: 3)
        stub(304, headers: ["X-Uplift-Flow-Version": "9"])
        _ = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
        let bumped = await waitUntil { [cache] in
            cache!.read(flowId: "demo")?.version == 9
        }
        XCTAssertTrue(bumped)
        XCTAssertEqual(cache.read(flowId: "demo")?.json, flowJson)
    }

    func testForceRefreshBypassesCacheAndAwaitsNetwork() async throws {
        seedCache()
        stub(200, headers: ["ETag": "\"def\""], json: updatedJson)
        let result = try await fetcher.fetch(
            url: url, flowId: "demo", apiKey: "k", forceRefresh: true)
        XCTAssertEqual(result.source, .network)
        XCTAssertEqual(result.json, updatedJson)
        // forceRefresh ignores the cached entry entirely — no If-None-Match.
        XCTAssertNil(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testForceRefreshNetworkErrorThrows() async throws {
        // forceRefresh drops the cache reference entirely (Dart parity):
        // an unreachable server then surfaces as a typed network error.
        seedCache()
        MockURLProtocol.handler = { _ in .error(URLError(.timedOut)) }
        do {
            _ = try await fetcher.fetch(
                url: url, flowId: "demo", apiKey: "k", forceRefresh: true)
            XCTFail("expected throw")
        } catch let error as FlowFetchError {
            XCTAssertEqual(error.kind, .network)
        }
    }

    // MARK: Experiment headers

    func testAssignmentParsedOn200AndCallbackFired() async throws {
        stub(200, headers: [
            "X-Uplift-Experiment": "exp_1:var_b",
            "X-Uplift-Variant-Name": "S%C3%BCper%20CTA",
        ], json: flowJson)

        let box = AssignmentBox()
        let result = try await fetcher.fetch(
            url: url, flowId: "demo", apiKey: "k",
            subjectId: "anon_123",
            onAssignment: { box.value = $0 })

        XCTAssertEqual(result.experimentAssignment?.experimentId, "exp_1")
        XCTAssertEqual(result.experimentAssignment?.variantId, "var_b")
        XCTAssertEqual(result.experimentAssignment?.variantName, "Süper CTA")
        XCTAssertEqual(box.value, result.experimentAssignment)
        XCTAssertEqual(
            MockURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Uplift-Subject-Id"),
            "anon_123")
    }

    func testAssignmentCallbackFiresFromBackgroundRevalidation() async throws {
        seedCache()
        stub(304, headers: ["X-Uplift-Experiment": "exp_1:var_a"])
        let box = AssignmentBox()
        let result = try await fetcher.fetch(
            url: url, flowId: "demo", apiKey: "k",
            onAssignment: { box.value = $0 })
        // Instant cache hit carries no assignment...
        XCTAssertNil(result.experimentAssignment)
        // ...but the background 304 reports it.
        let fired = await waitUntil { box.value != nil }
        XCTAssertTrue(fired)
        XCTAssertEqual(box.value?.variantId, "var_a")
    }

    // MARK: Bundle id header

    func testBundleIdHeaderSentWhenConfigured() async throws {
        stub(200, headers: ["ETag": "\"abc\""], json: flowJson)
        _ = try await fetcher.fetch(
            url: url, flowId: "demo", apiKey: "k",
            bundleId: "com.example.myapp")
        XCTAssertEqual(
            MockURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Uplift-Bundle-Id"),
            "com.example.myapp")
    }

    func testBundleIdHeaderOmittedWhenAbsent() async throws {
        stub(200, headers: ["ETag": "\"abc\""], json: flowJson)
        _ = try await fetcher.fetch(url: url, flowId: "demo", apiKey: "k")
        XCTAssertNil(
            MockURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Uplift-Bundle-Id"))
    }

    func testBundleIdHeaderCarriedByBackgroundRevalidation() async throws {
        seedCache()
        stub(304)
        let result = try await fetcher.fetch(
            url: url, flowId: "demo", apiKey: "k",
            bundleId: "com.example.myapp")
        XCTAssertEqual(result.source, .cache)
        let sawHeader = await waitUntil {
            MockURLProtocol.requests.contains {
                $0.value(forHTTPHeaderField: "X-Uplift-Bundle-Id") == "com.example.myapp"
            }
        }
        XCTAssertTrue(sawHeader)
    }
}

/// Reference box so @Sendable callbacks can hand results back to the test.
final class AssignmentBox: @unchecked Sendable {
    var value: UpliftFunnelExperimentAssignment?
}
