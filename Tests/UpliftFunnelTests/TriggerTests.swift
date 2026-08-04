import XCTest
@testable import UpliftFunnel

/// C3 — the client half of the trigger engine.
///
/// The client carries no rules, so almost nothing here is about deciding. What
/// it is about: asking at the right moments and not more often than that, and
/// telling the truth about what it managed to show.
@MainActor
final class TriggerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        defaults = UserDefaults(suiteName: "trigger-\(UUID().uuidString)")
    }

    override func tearDown() {
        UpliftFunnel.resetForTests()
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Decoding

    func testDecodesADecision() {
        let evaluation = TriggerEvaluation.decode(try! JSONValue.parse("""
        {"trigger_id":"trg_1","flow_slug":"winback",
         "presentation":{"mode":"sheet","dismissible":false,"delayMs":250},
         "profile":{"goal":"strength","weekly_days":4},
         "evaluate_on":["cart_abandoned","workout"]}
        """))

        let decision = try! XCTUnwrap(evaluation.decision)
        XCTAssertEqual(decision.triggerId, "trg_1")
        XCTAssertEqual(decision.flowSlug, "winback")
        XCTAssertEqual(decision.presentation.mode, .sheet)
        XCTAssertFalse(decision.presentation.dismissible)
        XCTAssertEqual(decision.presentation.delay, 0.25, accuracy: 0.001)
        // Numbers arrive as the string `{{...}}` would print, so a host
        // comparing against "4" is not depending on how the server stored it.
        XCTAssertEqual(evaluation.profile["weekly_days"], "4")
        XCTAssertEqual(evaluation.evaluateOn, ["cart_abandoned", "workout"])
    }

    func testNothingFiredIsNotAnError() {
        let evaluation = TriggerEvaluation.decode(try! JSONValue.parse("""
        {"trigger_id":null,"profile":{"goal":"strength"},"evaluate_on":[]}
        """))
        XCTAssertNil(evaluation.decision)
        // The profile still arrives — most calls fire nothing, and that is the
        // path the snapshot usually travels on.
        XCTAssertEqual(evaluation.profile["goal"], "strength")
    }

    func testDeclinesAModeItDoesNotKnow() {
        // A server that learns a fifth mode will send it to SDKs that predate
        // it. Rendering a `toast` as a full screen would put a flow somewhere
        // its author never agreed to (I30's shape: degrade, never invent).
        let evaluation = TriggerEvaluation.decode(try! JSONValue.parse("""
        {"trigger_id":"trg_1","flow_slug":"winback",
         "presentation":{"mode":"toast"},"profile":{},"evaluate_on":[]}
        """))
        XCTAssertNil(evaluation.decision)
    }

    func testDeclinesASlotModeWithNoSlot() {
        let evaluation = TriggerEvaluation.decode(try! JSONValue.parse("""
        {"trigger_id":"trg_1","flow_slug":"winback",
         "presentation":{"mode":"banner"},"profile":{},"evaluate_on":[]}
        """))
        XCTAssertNil(evaluation.decision)
    }

    func testFullscreenIsAlwaysDismissible() {
        let evaluation = TriggerEvaluation.decode(try! JSONValue.parse("""
        {"trigger_id":"trg_1","flow_slug":"winback",
         "presentation":{"mode":"fullscreen","dismissible":false},
         "profile":{},"evaluate_on":[]}
        """))
        XCTAssertTrue(try! XCTUnwrap(evaluation.decision).presentation.dismissible)
    }

    // MARK: - Asking

    func testStaysSilentUntilSomebodyCanShowSomething() async {
        // An SDK that starts calling a new endpoint on every foreground after a
        // version bump is a behaviour change nobody asked for — and the answer
        // would have nowhere to go.
        await configure()
        stubEvaluate(decision: sheetDecision)

        await UpliftFunnel.state?.triggers?.evaluate(reason: .foreground)
        XCTAssertEqual(evaluateCalls, 0)
        XCTAssertNil(UpliftFunnel.state?.triggers)
    }

    func testRegisteringAPresenterAsksOnce() async {
        await configure()
        stubEvaluate(decision: sheetDecision)
        let presenter = RecordingPresenter()

        UpliftFunnel.registerPresenter(presenter)
        await settle { self.presenterSaw(presenter) }

        XCTAssertEqual(evaluateCalls, 1)
        XCTAssertEqual(presenter.sheets, ["winback"])
    }

    func testDoesNotAskTwiceInsideAMinute() async {
        // Spec 15 criterion 5. Three moments can land in the same second on a
        // launch; the floor is what makes that one request.
        await configure()
        stubEvaluate(decision: nil)
        let coordinator = try! XCTUnwrap(makeCoordinator())

        await coordinator.evaluate(reason: .foreground)
        await coordinator.evaluate(reason: .tracked)
        await coordinator.evaluate(reason: .flowCompleted)
        XCTAssertEqual(evaluateCalls, 1)

        // …and asks again once the floor has passed.
        coordinator.now = { Date().addingTimeInterval(kUpliftTriggerDebounce + 1) }
        await coordinator.evaluate(reason: .foreground)
        XCTAssertEqual(evaluateCalls, 2)
    }

    func testSendsTheTimezoneOffsetQuietHoursNeed() async {
        // There is no timezone on the server. A build that does not send this
        // has quiet hours silently not applied, which is the kind of bug that
        // shows up as "why did it wake them at 3am".
        await configure()
        stubEvaluate(decision: nil)
        let coordinator = try! XCTUnwrap(makeCoordinator())
        await coordinator.evaluate(reason: .foreground)

        let body = try! XCTUnwrap(lastEvaluateBody())
        let context = try! XCTUnwrap(body["context"]?.objectValue)
        XCTAssertEqual(
            context["tz_offset_minutes"]?.intValue,
            TimeZone.current.secondsFromGMT() / 60)
    }

    func testTrackAsksOnlyForEventsTheServerNamed() async throws {
        // The allowlist comes from the server, so a new rule about a new event
        // starts working without a release — and every other `track()` is free.
        await configure()
        stubEvaluate(decision: nil, evaluateOn: ["cart_abandoned"])
        let presenter = RecordingPresenter()
        UpliftFunnel.registerPresenter(presenter)
        await settle { self.evaluateCalls == 1 }

        let coordinator = try XCTUnwrap(UpliftFunnel.state?.triggers)
        coordinator.now = { Date().addingTimeInterval(kUpliftTriggerDebounce + 1) }

        try await UpliftFunnel.track("something_else")
        XCTAssertEqual(evaluateCalls, 1)

        try await UpliftFunnel.track("cart_abandoned")
        XCTAssertEqual(evaluateCalls, 2)

        // The event rides along, because it is still in the upload queue and a
        // trigger about the thing that just happened should not wait for it.
        let body = try XCTUnwrap(lastEvaluateBody())
        let recent = try XCTUnwrap(body["recent_events"]?.arrayValue)
        XCTAssertEqual(recent.first?.objectValue?["event_type"]?.stringValue, "cart_abandoned")
    }

    // MARK: - Presenting

    func testReportsWhatThePresenterRefused() async {
        await configure()
        stubEvaluate(decision: sheetDecision)
        let presenter = RecordingPresenter()
        presenter.accept = false

        UpliftFunnel.registerPresenter(presenter)
        await settle { self.outcomeBodies.count == 1 }

        let body = try! XCTUnwrap(outcomeBodies.first)
        XCTAssertEqual(body["outcome"]?.stringValue, "unpresentable")
        XCTAssertEqual(body["reason"]?.stringValue, "presenter_failed")
    }

    func testHoldsASlotDecisionUntilTheSlotArrives() async throws {
        // A card decided while the user is two screens from its slot should
        // appear when they get there. Refusing on the spot would make a
        // slot-mode trigger reachable only in the second its screen happens to
        // be visible.
        await configure()
        stubEvaluate(decision: bannerDecision)
        let coordinator = try XCTUnwrap(makeCoordinator())

        await coordinator.evaluate(reason: .foreground)
        XCTAssertEqual(coordinator.pendingDecision?.triggerId, "trg_1")
        XCTAssertTrue(outcomeBodies.isEmpty)

        var delivered: UpliftTriggerDecision?
        coordinator.attach(slot: "home_top") { delivered = $0 }
        XCTAssertEqual(delivered?.flowSlug, "winback")
        XCTAssertNil(coordinator.pendingDecision)
        XCTAssertTrue(outcomeBodies.isEmpty)
    }

    func testReportsNoSlotWhenTheAppLeavesWithoutOne() async throws {
        // Spec 15 criterion 6: the slot was never placed, so the delivery log
        // must stop claiming a delivery. The server flips the row back, which
        // is also why this does not spend the frequency cap.
        await configure()
        stubEvaluate(decision: bannerDecision)
        let coordinator = try XCTUnwrap(makeCoordinator())
        await coordinator.evaluate(reason: .foreground)

        coordinator.appLeftForeground()
        await settle { self.outcomeBodies.count == 1 }

        let body = try XCTUnwrap(outcomeBodies.first)
        XCTAssertEqual(body["trigger_id"]?.stringValue, "trg_1")
        XCTAssertEqual(body["outcome"]?.stringValue, "unpresentable")
        XCTAssertEqual(body["reason"]?.stringValue, "no_slot")
        XCTAssertNil(coordinator.pendingDecision)
    }

    func testReportsTheOutcomeOfAFlowATriggerOpened() async throws {
        await configure()
        stubEvaluate(decision: sheetDecision)
        let presenter = RecordingPresenter()
        UpliftFunnel.registerPresenter(presenter)
        await settle { self.presenterSaw(presenter) }

        let coordinator = try XCTUnwrap(UpliftFunnel.state?.triggers)
        await coordinator.flowEnded(flowSlug: "winback", reason: "completed")
        await settle { self.outcomeBodies.count == 1 }

        let body = try XCTUnwrap(outcomeBodies.first)
        XCTAssertEqual(body["outcome"]?.stringValue, "completed")
        XCTAssertEqual(body["trigger_id"]?.stringValue, "trg_1")
    }

    func testSaysNothingAboutAFlowItDidNotOpen() async throws {
        await configure()
        stubEvaluate(decision: sheetDecision)
        let presenter = RecordingPresenter()
        UpliftFunnel.registerPresenter(presenter)
        await settle { self.presenterSaw(presenter) }

        let coordinator = try XCTUnwrap(UpliftFunnel.state?.triggers)
        await coordinator.flowEnded(flowSlug: "some-other-flow", reason: "completed")

        // Only the evaluation that a finished flow prompts — no outcome for a
        // flow the host started on its own.
        XCTAssertTrue(outcomeBodies.isEmpty)
    }

    // MARK: - Profile

    func testServerSnapshotFillsGapsAndNeverOverwrites() async throws {
        // Spec 15 §2's ordering. A local value is newer, or is a `sensitive`
        // answer the server has never seen — either way it wins, or an answer
        // would visibly revert mid-session.
        await configure()
        let state = try XCTUnwrap(UpliftFunnel.state)
        state.profile.set("goal", "strength")

        stubEvaluate(
            decision: nil,
            profile: ["goal": "endurance", "city": "Istanbul"])
        let coordinator = try XCTUnwrap(makeCoordinator())
        await coordinator.evaluate(reason: .foreground)

        XCTAssertEqual(UpliftFunnel.profile("goal"), "strength")
        // …and the half a local store cannot have: an answer from another
        // device, or from before a reinstall.
        XCTAssertEqual(UpliftFunnel.profile("city"), "Istanbul")
    }

    // MARK: - Helpers

    private func configure() async {
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            urlSession: MockURLProtocol.session(), defaults: defaults)
    }

    /// A coordinator with no presenter and no slot would be dormant, so the
    /// tests that drive it directly mount a slot sink that ignores everything.
    private func makeCoordinator() -> TriggerCoordinator? {
        guard let coordinator = UpliftFunnel.state?.ensureTriggers() else { return nil }
        coordinator.attach(slot: "__test") { _ in }
        return coordinator
    }

    private var sheetDecision: String {
        """
        "trigger_id":"trg_1","flow_slug":"winback",
        "presentation":{"mode":"sheet","dismissible":true,"delayMs":0}
        """
    }

    private var bannerDecision: String {
        """
        "trigger_id":"trg_1","flow_slug":"winback",
        "presentation":{"mode":"banner","slot":"home_top","dismissible":true,"delayMs":0}
        """
    }

    private func stubEvaluate(
        decision: String?,
        profile: [String: String] = [:],
        evaluateOn: [String] = []
    ) {
        let profileJson = profile.isEmpty
            ? "{}"
            : "{" + profile.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        let allowlist = "[" + evaluateOn.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let body = """
        {\(decision.map { $0 + "," } ?? "\"trigger_id\":null,")
         "profile":\(profileJson),"evaluate_on":\(allowlist)}
        """
        MockURLProtocol.handler = { _ in .stub(.init(statusCode: 200, json: body)) }
    }

    private var evaluateCalls: Int {
        MockURLProtocol.recorded.filter { $0.url?.path == "/v1/triggers/evaluate" }.count
    }

    private var outcomeBodies: [[String: JSONValue]] {
        MockURLProtocol.recorded
            .filter { $0.url?.path == "/v1/triggers/outcome" }
            .compactMap { $0.bodyJSON?.objectValue }
    }

    private func lastEvaluateBody() -> [String: JSONValue]? {
        MockURLProtocol.recorded
            .last { $0.url?.path == "/v1/triggers/evaluate" }?
            .bodyJSON?.objectValue
    }

    private func presenterSaw(_ presenter: RecordingPresenter) -> Bool {
        !presenter.sheets.isEmpty || !presenter.fullscreens.isEmpty || !outcomeBodies.isEmpty
    }

    /// Await fire-and-forget work — the coordinator reports outcomes in a
    /// detached task so a slow network never blocks a presentation.
    private func settle(
        timeout: TimeInterval = 2, until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class RecordingPresenter: UpliftPresenter {
    var accept = true
    var fullscreens: [String] = []
    var sheets: [String] = []

    func presentFullscreen(flowKey: String, dismissible: Bool) async -> Bool {
        fullscreens.append(flowKey)
        return accept
    }

    func presentSheet(flowKey: String, dismissible: Bool) async -> Bool {
        sheets.append(flowKey)
        return accept
    }
}
