// The answer profile: what the host can read, when, and what never gets in.
//
// Two boundaries are load-bearing here and neither is obvious from the API
// shape. The profile holds ANSWERS — not the flow's declared defaults, not the
// prices the host published, not the variables the host passed in itself — so
// that "what has this person told us?" keeps having an answer. And it keeps
// filling while analytics is off: consent governs what leaves the device, not
// what the app may know about its own user.

import XCTest
@testable import UpliftFunnel

@MainActor
final class ProfileTests: XCTestCase {
    private var defaults: UserDefaults!

    /// A flow with a declared default, so the tests can prove a default is not
    /// an answer.
    private let flowJson = """
    {"schema_version":1,"id":"demo","entry_screen_id":"welcome",
     "variables":[
       {"name":"goal","type":"string","default":"unset"},
       {"name":"email","type":"string","sensitive":true}
     ],
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

    private func configure(trackingEnabled: Bool = true) async {
        await UpliftFunnel.configureInternal(
            apiKey: "fnl_pk_test", serverUrl: "https://api.example.com",
            trackingEnabled: trackingEnabled,
            urlSession: MockURLProtocol.session(), defaults: defaults)
    }

    private func session(userVariables: [String: JSONValue]? = nil) throws -> FlowSession {
        try XCTUnwrap(UpliftFunnel.state).session(
            fromJson: flowJson, userVariables: userVariables)
    }

    // MARK: - The store itself

    func testStoreSurvivesARestart() {
        let store = ProfileStore(defaults: defaults)
        store.set("goal", "muscle")

        // A second store over the same defaults is what the next app launch
        // sees.
        XCTAssertEqual(ProfileStore(defaults: defaults).value("goal"), "muscle")
    }

    /// Drain exactly `count` changes. `AsyncStream` buffers what was yielded
    /// before anyone iterated, so writing first and reading after is
    /// deterministic — no sleeping, and nothing to be flaky about.
    private func drain(
        _ stream: AsyncStream<ProfileChange>, count: Int
    ) async -> [ProfileChange] {
        var seen: [ProfileChange] = []
        for await change in stream {
            seen.append(change)
            if seen.count == count { break }
        }
        return seen
    }

    func testUnchangedWriteDoesNotNotify() async {
        let store = ProfileStore(defaults: defaults)
        let stream = store.changes()

        store.set("goal", "muscle")
        store.set("goal", "muscle")
        // A sentinel behind the duplicate: if the second write had notified,
        // it would be sitting between these two and the pair would read
        // ["goal", "goal"].
        store.set("pace", "fast")

        let seen = await drain(stream, count: 2)
        XCTAssertEqual(seen.map(\.key), ["goal", "pace"])
    }

    func testEachObserverGetsItsOwnStream() {
        let store = ProfileStore(defaults: defaults)
        _ = store.changes()
        _ = store.changes()
        XCTAssertEqual(store.observerCount, 2)
    }

    func testClearReportsEveryDroppedKey() async {
        let store = ProfileStore(defaults: defaults)
        store.set("goal", "muscle")
        store.set("pace", "fast")

        let stream = store.changes()
        store.clear()
        let seen = await drain(stream, count: 2)

        // A host that reacted to a value appearing has to be able to react to
        // it going away.
        XCTAssertEqual(seen.map(\.key).sorted(), ["goal", "pace"])
        XCTAssertTrue(seen.allSatisfy { $0.value == nil })
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(defaults.dictionary(forKey: kUpliftProfileDefaultsKey))
    }

    // MARK: - What gets in

    func testAnAnswerLandsInTheProfileWhileTheFlowIsStillRunning() async throws {
        await configure()
        let session = try session()

        session.setVariable("goal", .string("muscle"))

        XCTAssertEqual(UpliftFunnel.profile("goal"), "muscle")
        XCTAssertFalse(session.completed, "read mid-flow, not at completion")
    }

    func testDeclaredDefaultsAreNotAnswers() async throws {
        await configure()
        _ = try session()

        // `goal` has a default of "unset" and the engine seeded it — but
        // nobody said it.
        XCTAssertNil(UpliftFunnel.profile("goal"))
        XCTAssertTrue(UpliftFunnel.profileAll().isEmpty)
    }

    func testHostSuppliedVariablesAreNotAnswers() async throws {
        await configure()
        _ = try session(userVariables: ["goal": .string("muscle")])

        // The host passed it in; telling them back what they told us would be
        // the profile's only lie.
        XCTAssertNil(UpliftFunnel.profile("goal"))
    }

    func testProductValuesAreNotAnswers() async throws {
        await configure()
        UpliftFunnel.setProducts([
            UpliftFunnelProduct(id: "pro_yearly", price: "$49.99")
        ])
        _ = try session()

        XCTAssertTrue(
            UpliftFunnel.profileAll().keys.allSatisfy { !$0.hasPrefix("price") },
            "a store fact is not something the person said")
    }

    func testLocalWritesLandWhenTheyCommit() async throws {
        await configure()
        let session = try session()

        // Per-keystroke writes do not emit `variable_set` and must not write
        // the profile either — otherwise `profileChanges` fires per character.
        session.setVariableLocal("goal", .string("mus"))
        XCTAssertNil(UpliftFunnel.profile("goal"))

        session.setVariableLocal("goal", .string("muscle"))
        session.commitVariable("goal")
        XCTAssertEqual(UpliftFunnel.profile("goal"), "muscle")
    }

    func testMultiSelectRoundTripsAsTheRendererSpellsIt() async throws {
        await configure()
        let session = try session()

        session.setVariable("goal", .array([.string("a"), .string("b")]))

        // The same string the flow interpolates for `{{goal}}` — two spellings
        // of one answer would be a bug nobody could reproduce.
        XCTAssertEqual(UpliftFunnel.profile("goal"), #"["a","b"]"#)
    }

    // MARK: - Sensitive and consent

    func testSensitiveAnswersReachTheHostAndPersist() async throws {
        await configure()
        let session = try session()

        session.setVariable("email", .string("someone@example.com"))

        // `sensitive` has always meant "the host sees it, the Uplift API does
        // not". The host is who reads this.
        XCTAssertEqual(UpliftFunnel.profile("email"), "someone@example.com")
        XCTAssertEqual(
            ProfileStore(defaults: defaults).value("email"), "someone@example.com",
            "withholding it after a restart would be a difference no caller can see")
    }

    func testSensitiveAnswerStillNeverReachesTelemetry() async throws {
        await configure()
        let session = try session()
        let uploader = try XCTUnwrap(UpliftFunnel.state?.uploader)

        session.setVariable("email", .string("someone@example.com"))

        // The enqueue runs in a detached Task. Wait on the condition rather
        // than on a duration — a sleep long enough to be reliable is a sleep
        // long enough to be slow, and a short one is a flake waiting for CI.
        var emailEvent: [String: JSONValue]?
        for _ in 0..<200 where emailEvent == nil {
            emailEvent = await uploader.bufferedEvents.first { event in
                event["event_type"]?.stringValue == "variable_set"
                    && event["payload"]?["name"].stringValue == "email"
            }
            if emailEvent == nil { await Task.yield() }
        }
        let event = try XCTUnwrap(emailEvent)
        XCTAssertEqual(event["payload"]?["redacted"].boolValue, true)
        XCTAssertNil(event["payload"]?["value"].stringValue)
    }

    func testProfileKeepsFillingWithAnalyticsOff() async throws {
        await configure(trackingEnabled: false)
        let session = try session()

        session.setVariable("goal", .string("muscle"))

        XCTAssertEqual(
            UpliftFunnel.profile("goal"), "muscle",
            "consent governs what leaves the device, not what the app knows")
    }

    func testResetIdentityEmptiesTheProfile() async throws {
        await configure()
        let session = try session()
        session.setVariable("goal", .string("muscle"))

        try await UpliftFunnel.resetIdentity()

        // A fresh anonymous id means a different person; inheriting the last
        // one's answers is the same mistake as inheriting their variant.
        XCTAssertNil(UpliftFunnel.profile("goal"))
        XCTAssertNil(ProfileStore(defaults: defaults).value("goal"))
    }

    func testUnconfiguredReadsAreEmptyRatherThanHanging() async {
        XCTAssertNil(UpliftFunnel.profile("goal"))
        XCTAssertTrue(UpliftFunnel.profileAll().isEmpty)

        var received = 0
        for await _ in UpliftFunnel.profileChanges { received += 1 }
        XCTAssertEqual(received, 0, "the stream finishes instead of hanging forever")
    }
}
