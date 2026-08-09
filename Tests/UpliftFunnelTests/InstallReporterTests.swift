import XCTest
@testable import UpliftFunnel

/// F1 — the install handshake.
///
/// The reporter exists because two facts the dashboard's setup gate needs
/// never leave the device. The one thing it must not get wrong is *when* it
/// speaks: `registerPresenter` and `setProducts` are always called after
/// `configure`, so a report sent from `configure` would tell the server "no
/// presenter" about every correctly-wired app there is.
@MainActor
final class InstallReporterTests: XCTestCase {
    private var defaults: UserDefaults!
    /// Held in a property because the SDK keeps the presenter weakly.
    /// `RecordingPresenter` is the suite's existing double, from `TriggerTests`.
    private var presenter: RecordingPresenter?

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        defaults = UserDefaults(suiteName: "install-\(UUID().uuidString)")
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{\"ok\":true}")) }
    }

    override func tearDown() {
        presenter = nil
        UpliftFunnel.resetForTests()
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Wait for a condition rather than for a duration.
    ///
    /// A fixed sleep is how this suite got a flaky test once already: it makes
    /// the assertion depend on how loaded the machine is, and it fails on the
    /// slow run rather than the wrong one.
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func installRequests() -> [MockURLProtocol.Recorded] {
        MockURLProtocol.recorded.filter { $0.url?.path == "/v1/install" }
    }

    /// The box a reporter under test reads from, so a test can change what
    /// the app looks like the same way the facade does.
    private var box: InstallSnapshotBox!

    private func makeReporter(
        hasPresenter: Bool = false,
        productCount: Int = 0,
        coalesceDelay: TimeInterval = 0.05,
        resendInterval: TimeInterval = 24 * 60 * 60,
        apiKey: String = "fnl_pk_test",
        installationId: String? = "anon_test",
        trackingEnabled: Bool = true
    ) -> InstallReporter {
        box = InstallSnapshotBox(
            InstallSnapshot(
                sdkVersion: kUpliftFunnelSdkVersion,
                platform: "ios",
                osVersion: "18.0",
                appVersion: "2.4.1",
                hasPresenter: hasPresenter,
                productCount: productCount))
        var config = InstallReporter.Config(
            endpoint: URL(string: "https://api.example.com/v1/install")!,
            apiKeyProvider: { apiKey },
            bundleIdProvider: { "com.example.app" },
            installationIdProvider: { installationId },
            urlSession: MockURLProtocol.session(),
            store: UserDefaultsInstallFingerprintStore(defaults: defaults),
            snapshot: box)
        config.coalesceDelay = coalesceDelay
        config.resendInterval = resendInterval
        return InstallReporter(config: config, trackingEnabled: trackingEnabled)
    }

    /// Change what the app looks like, then tell the reporter — exactly the
    /// two steps `noteInstallChanged` takes.
    private func change(
        _ reporter: InstallReporter,
        _ mutate: (inout InstallSnapshot) -> Void
    ) async {
        var next = box.value
        mutate(&next)
        box.value = next
        await reporter.noteChanged()
    }

    // MARK: - Coalescing

    func testThreeChangesAtLaunchProduceOneRequest() async {
        let reporter = makeReporter()

        // The startup sequence, as every host writes it.
        await change(reporter) { $0.hasPresenter = false }   // configure
        await change(reporter) { $0.hasPresenter = true }    // registerPresenter
        await change(reporter) { $0.productCount = 3 }       // setProducts

        await waitUntil { self.installRequests().count >= 1 }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(installRequests().count, 1)
        let body = installRequests()[0].bodyJSON?.objectValue
        // And it describes the app *after* wiring, which is the whole point.
        XCTAssertEqual(body?["has_presenter"]?.boolValue, true)
        XCTAssertEqual(body?["product_count"]?.intValue, 3)
    }

    func testTheReportCarriesTheBuildAndTheDeviceId() async {
        let reporter = makeReporter(hasPresenter: true, productCount: 2)
        await reporter.flush()

        let recorded = installRequests().first
        XCTAssertNotNil(recorded)
        let body = recorded?.bodyJSON?.objectValue
        XCTAssertEqual(body?["installation_id"]?.stringValue, "anon_test")
        XCTAssertEqual(body?["sdk_version"]?.stringValue, kUpliftFunnelSdkVersion)
        XCTAssertEqual(body?["platform"]?.stringValue, "ios")
        XCTAssertEqual(body?["os_version"]?.stringValue, "18.0")
        XCTAssertEqual(body?["app_version"]?.stringValue, "2.4.1")
        XCTAssertEqual(recorded?.header("Authorization"), "Bearer fnl_pk_test")
        XCTAssertEqual(recorded?.header("X-Uplift-Bundle-Id"), "com.example.app")
        // The server rations this per device: a public key is shared by every
        // install, so keying the limit on it would ration the whole user base.
        XCTAssertEqual(recorded?.header("X-Uplift-Subject-Id"), "anon_test")
    }

    // MARK: - Quiet after the first report

    func testAnUnchangedReportIsNotSentAgain() async {
        let reporter = makeReporter(hasPresenter: true, productCount: 1)
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 1)

        await reporter.flush()
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 1)
    }

    func testTheFingerprintDoesNotDependOnDictionaryOrder() {
        // The first version of this took the fingerprint from the serialized
        // body, and `JSONEncoder` writes a dictionary in iteration order —
        // which differs between two dictionaries holding identical contents,
        // in the same process. Every launch then looked like a change.
        let snapshot = InstallSnapshot(
            sdkVersion: "0.10.0", platform: "ios", osVersion: "18.0",
            appVersion: "2.4.1", hasPresenter: true, productCount: 1)
        let a = InstallReporter.fingerprint(snapshot, installationId: "anon_test")
        let b = InstallReporter.fingerprint(snapshot, installationId: "anon_test")
        XCTAssertEqual(a, b)

        var changed = snapshot
        changed.productCount = 2
        XCTAssertNotEqual(
            a, InstallReporter.fingerprint(changed, installationId: "anon_test"))
        XCTAssertNotEqual(
            a, InstallReporter.fingerprint(snapshot, installationId: "anon_other"))
    }

    func testAFieldGoingMissingIsNotTheSameReport() {
        // Separator-joined rather than concatenated: "18.0" + "" and "18" +
        // ".0" must not collide.
        let base = InstallSnapshot(
            sdkVersion: "0.10.0", platform: "ios", osVersion: "18.0",
            appVersion: nil, hasPresenter: false, productCount: 0)
        var shifted = base
        shifted.osVersion = "18"
        shifted.appVersion = "0"
        XCTAssertNotEqual(
            InstallReporter.fingerprint(base, installationId: "a"),
            InstallReporter.fingerprint(shifted, installationId: "a"))
    }

    func testAChangedReportIsSent() async {
        let reporter = makeReporter(hasPresenter: false)
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 1)

        await change(reporter) { $0.hasPresenter = true }
        await waitUntil { self.installRequests().count >= 2 }
        XCTAssertEqual(installRequests().count, 2)
        XCTAssertEqual(
            installRequests()[1].bodyJSON?.objectValue?["has_presenter"]?.boolValue, true)
    }

    func testAnUnchangedReportIsRepeatedOnceTheIntervalPasses() async {
        let first = makeReporter(hasPresenter: true, resendInterval: 0)
        await first.flush()
        XCTAssertEqual(installRequests().count, 1)

        // Same body, same store — only the interval has lapsed.
        let second = makeReporter(hasPresenter: true, resendInterval: 0)
        await second.flush()
        XCTAssertEqual(installRequests().count, 2)
    }

    func testAFailedSendDoesNotSuppressTheNextOne() async {
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 500)) }
        let reporter = makeReporter(hasPresenter: true)
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 1)

        // Nothing was recorded as accepted, so the identical body goes again.
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: "{}")) }
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 2)
    }

    func testAnUnreachableServerIsSwallowed() async {
        MockURLProtocol.handler = { _ in .error(URLError(.notConnectedToInternet)) }
        let reporter = makeReporter(hasPresenter: true)
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 1)
    }

    // MARK: - When it must stay silent

    func testConsentOffSendsNothing() async {
        // The server reads the silence as "not measured", never as "no
        // presenter" — which is why those columns are nullable server-side.
        let reporter = makeReporter(hasPresenter: true, trackingEnabled: false)
        await change(reporter) { $0.productCount = 4 }
        await reporter.flush()
        XCTAssertEqual(installRequests().count, 0)
    }

    func testConsentWithdrawnCancelsAPendingReport() async {
        let reporter = makeReporter(coalesceDelay: 0.3)
        await change(reporter) { $0.hasPresenter = true }
        await reporter.setTrackingEnabled(false)

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(installRequests().count, 0)
    }

    func testNoKeyAndNoInstallationIdSendNothing() async {
        await makeReporter(hasPresenter: true, apiKey: "").flush()
        XCTAssertEqual(installRequests().count, 0)

        await makeReporter(hasPresenter: true, installationId: nil).flush()
        XCTAssertEqual(installRequests().count, 0)
    }

    func testCloseCancelsAndStopsScheduling() async {
        let reporter = makeReporter(coalesceDelay: 0.3)
        await change(reporter) { $0.hasPresenter = true }
        await reporter.close()
        await change(reporter) { $0.productCount = 9 }

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(installRequests().count, 0)
    }

    // MARK: - Wired to the facade

    func testTheFacadeReportsWhatTheHostActuallyRegistered() async {
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            appVersion: "3.1.0",
            urlSession: MockURLProtocol.session(), defaults: defaults)
        // Held in a property: the SDK keeps the presenter weakly, so a local
        // temporary would be gone before the snapshot is read.
        presenter = RecordingPresenter()
        UpliftFunnel.registerPresenter(presenter!)
        UpliftFunnel.setProducts([
            UpliftFunnelProduct(id: "monthly", price: "$9.99"),
            UpliftFunnelProduct(id: "yearly", price: "$59.99"),
        ])

        // Skip the coalescing wait; the point here is the wiring, and the
        // coalescing has its own test.
        await UpliftFunnel.state?.installReporter?.flush()

        let body = installRequests().last?.bodyJSON?.objectValue
        XCTAssertEqual(body?["has_presenter"]?.boolValue, true)
        XCTAssertEqual(body?["product_count"]?.intValue, 2)
        XCTAssertEqual(body?["app_version"]?.stringValue, "3.1.0")
        // The device id events already carry, not a second identifier.
        XCTAssertEqual(
            body?["installation_id"]?.stringValue,
            defaults.string(forKey: FunnelState.anonymousIdKey))
    }

    func testAConfigureWithNoWiringReportsHonestly() async {
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            urlSession: MockURLProtocol.session(), defaults: defaults)
        await UpliftFunnel.state?.installReporter?.flush()

        let body = installRequests().last?.bodyJSON?.objectValue
        XCTAssertEqual(body?["has_presenter"]?.boolValue, false)
        XCTAssertEqual(body?["product_count"]?.intValue, 0)
    }

    func testConfigureIsNotBlockedByTheReport() async {
        MockURLProtocol.handler = { _ in .error(URLError(.timedOut)) }
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            urlSession: MockURLProtocol.session(), defaults: defaults)
        XCTAssertTrue(UpliftFunnel.isConfigured)
    }
}
