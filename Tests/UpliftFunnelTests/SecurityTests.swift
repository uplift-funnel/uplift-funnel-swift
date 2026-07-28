// Security regressions: the SDK renders and acts on JSON it fetched over the
// network, so the places where authored content reaches the OS (a `url:`
// action) and where the host's config reaches the wire (`serverUrl`, the flow
// key, redirects) all need to stay locked down.

import XCTest
@testable import UpliftFunnel

@MainActor
final class SecurityTests: XCTestCase {
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

    private func stubFlow() {
        MockURLProtocol.handler = { [flowJson] _ in
            .stub(.init(statusCode: 200, json: flowJson))
        }
    }

    // MARK: - url: scheme policy

    func testAllowsWebAndContactSchemes() {
        for url in [
            "https://example.com/terms",
            "http://example.com/terms",
            "mailto:support@example.com",
            "tel:+15551234567",
            "sms:+15551234567",
            "HTTPS://example.com",  // scheme match is case-insensitive
        ] {
            XCTAssertTrue(
                isAllowedLinkURL(url, allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes),
                url)
        }
    }

    func testBlocksAppSchemesLocalFilesAndScriptURLs() {
        for url in [
            "myapp://reset-password",          // the host app's own deep link
            "otherapp://transfer?amount=100",  // a third-party app
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "terms",                           // relative — no base to resolve
            "",
            "   ",
        ] {
            XCTAssertFalse(
                isAllowedLinkURL(url, allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes),
                url)
        }
    }

    func testOpenLinkForwardsAllowedURL() async {
        await configure()
        let opened = Box<[String]>([])
        UpliftFunnel.registerLinkHandler { opened.value.append($0) }

        XCTAssertTrue(UpliftFunnel.openLink("https://example.com/terms"))
        XCTAssertEqual(opened.value, ["https://example.com/terms"])
    }

    func testOpenLinkDropsDisallowedURLBeforeTheHandler() async {
        await configure()
        let opened = Box<[String]>([])
        UpliftFunnel.registerLinkHandler { opened.value.append($0) }

        XCTAssertFalse(UpliftFunnel.openLink("myapp://reset-password"))
        XCTAssertTrue(opened.value.isEmpty)
    }

    func testHostCanOptItsOwnSchemeIn() async {
        await configure()
        let opened = Box<[String]>([])
        UpliftFunnel.registerLinkHandler(
            { opened.value.append($0) },
            allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes.union(["myapp"]))

        XCTAssertTrue(UpliftFunnel.openLink("myapp://reset-password"))
        XCTAssertEqual(opened.value, ["myapp://reset-password"])
        // Opting one scheme in doesn't open the gate for the rest.
        XCTAssertFalse(UpliftFunnel.openLink("file:///etc/passwd"))
    }

    func testAllowListSurvivesReconfigure() async {
        await configure()
        let opened = Box<[String]>([])
        UpliftFunnel.registerLinkHandler(
            { opened.value.append($0) },
            allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes.union(["myapp"]))
        await configure(apiKey: "fnl_pk_second")

        XCTAssertTrue(UpliftFunnel.openLink("myapp://reset-password"))
        XCTAssertEqual(opened.value, ["myapp://reset-password"])
    }

    func testOpenLinkIsNoOpWithoutHandler() async {
        await configure()
        XCTAssertFalse(UpliftFunnel.openLink("https://example.com"))
    }

    // MARK: - serverUrl validation

    func testKeepsHTTPSAndStripsTrailingSlashes() throws {
        XCTAssertEqual(
            try normalizeServerUrl("https://api.upliftfunnel.com/", allowCleartext: false),
            "https://api.upliftfunnel.com")
        XCTAssertEqual(
            try normalizeServerUrl("  https://api.x.com//  ", allowCleartext: false),
            "https://api.x.com")
    }

    func testCleartextIsDebugOnly() throws {
        XCTAssertEqual(
            try normalizeServerUrl("http://127.0.0.1:3000", allowCleartext: true),
            "http://127.0.0.1:3000")
        XCTAssertThrowsError(
            try normalizeServerUrl("http://127.0.0.1:3000", allowCleartext: false)
        ) { error in
            guard case ServerURLError.cleartextInRelease = error else {
                return XCTFail("wrong case: \(error)")
            }
        }
    }

    func testRejectsNonAbsoluteHTTPServerURLs() {
        for url in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "ftp://example.com",
            "api.upliftfunnel.com",
            "not a url",
            "",
        ] {
            XCTAssertThrowsError(
                try normalizeServerUrl(url, allowCleartext: true), url)
        }
    }

    // MARK: - request hardening

    func testFlowKeyIsEncodedAsASinglePathSegment() async throws {
        await configure()
        stubFlow()

        _ = try await UpliftFunnel.start("../../admin?x=1")

        // Asserted on absoluteString, not `.path` — the latter hands back a
        // percent-DECODED path, which would read as if nothing was encoded.
        let requested = try XCTUnwrap(MockURLProtocol.requests.first?.url)
        XCTAssertEqual(
            requested.absoluteString,
            "https://api.example.com/v1/flows/..%2F..%2Fadmin%3Fx%3D1")
        XCTAssertNil(requested.query)
    }

    func testPlainSlugIsUntouched() async throws {
        await configure()
        stubFlow()

        _ = try await UpliftFunnel.start("cal-ai-clone")

        XCTAssertEqual(
            MockURLProtocol.requests.first?.url?.path, "/v1/flows/cal-ai-clone")
    }

    func testUnusableFlowKeysAreRefused() async {
        await configure()
        stubFlow()

        for key in ["", "..", ".", "   "] {
            do {
                _ = try await UpliftFunnel.start(key)
                XCTFail("expected throw for '\(key)'")
            } catch let error as FlowFetchError {
                XCTAssertEqual(error.kind, .notFound)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testRedirectsAreNotFollowed() async {
        // A 3xx would otherwise re-send Authorization + X-Uplift-Subject-Id to
        // whatever host the Location header names.
        await configure()
        MockURLProtocol.handler = { _ in
            .stub(.init(
                statusCode: 302,
                headers: ["Location": "https://attacker.example/steal"]))
        }

        do {
            _ = try await UpliftFunnel.start("demo")
            XCTFail("expected the 302 to surface as an error")
        } catch is FlowFetchError {
            // Expected: the 3xx falls through to the non-2xx path.
        } catch {
            XCTFail("unexpected \(error)")
        }

        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertNil(
            MockURLProtocol.requests.first { $0.url?.host == "attacker.example" },
            "the SDK followed the redirect")
    }

    func testProductionSessionRefusesRedirects() {
        XCTAssertTrue(FlowFetcher.makeSession().delegate is NoRedirectDelegate)
    }
}

