import XCTest
@testable import UpliftFunnel

/// C5 — the client half of in-flow inference.
///
/// One claim dominates this file and it is spec 15 criterion 4: `infer:` applies
/// the fallback and **the flow moves on**. Never hangs. Every failure the
/// network, the server, the user's camera roll or a misconfigured account can
/// produce ends with the session on a different screen than it started on, and
/// each of those paths gets its own test — because the one that is missing is
/// the one that strands a real user on a spinner in a country with a worse
/// network than this machine has.
@MainActor
final class InferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        UpliftFunnel.resetForTests()
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - fixtures

    /// capture → analysing → done. The aspect sits on the loading screen's
    /// root, so it auto-starts on entry; the capture screen's CTA consents and
    /// fires it explicitly.
    private func makeFlow(
        fallback: String = #"{"kind":"skip"}"#,
        requiresConsent: Bool = true,
        photoInput: Bool = true,
        timeoutMs: Int = 30_000
    ) throws -> FunnelFlow {
        let inputs = photoInput
            ? #"{"image":{"kind":"photo","name":"selfie"}}"#
            : #"{"goal":{"kind":"variable","name":"goal"}}"#
        return try FunnelFlow(json: JSONValue.parse("""
        {
          "schema_version": 3,
          "id": "skin_flow",
          "entry_screen_id": "capture",
          "variables": [
            {"name": "selfie", "type": "string"},
            {"name": "goal", "type": "string", "default": "clear"},
            {"name": "skin_type", "type": "string", "default": "unknown"},
            {"name": "score", "type": "number", "default": 0}
          ],
          "screens": [
            {
              "id": "capture",
              "root": {"type": "box", "children": [
                {"type": "box", "behavior": {"tap": ["consent:skin", "infer:skin"]},
                 "children": [{"type": "text", "props": {"value": "Analyse"}}]}
              ]},
              "transitions": [{"go": "analysing"}]
            },
            {
              "id": "analysing",
              "root": {
                "type": "box",
                "behavior": {"inference": {
                  "id": "skin",
                  "capability": "image_analysis",
                  "inputs": \(inputs),
                  "outputs": {"skin_type": "skin_type", "score": "score"},
                  "timeout_ms": \(timeoutMs),
                  "fallback": \(fallback),
                  "cost_cap_micros": 50000,
                  "requires_consent": \(requiresConsent)
                }},
                "children": [{"type": "text",
                              "props": {"value": "{{inference.skin.status}}"}}]
              },
              "transitions": [{"go": "done"}]
            },
            {
              "id": "done",
              "root": {"type": "box", "children": [
                {"type": "text", "props": {"value": "Done"}}
              ]},
              "transitions": [{"go": "end:done"}]
            },
            {
              "id": "manual",
              "root": {"type": "box", "children": [
                {"type": "text", "props": {"value": "Tell us yourself"}}
              ]},
              "transitions": [{"go": "end:manual"}]
            }
          ]
        }
        """))
    }

    /// A one-pixel JPEG on disk, so the local resolver has something real to
    /// read. Byte-level validity does not matter — nothing here decodes it
    /// except the pre-filter, which is exercised separately.
    private func writeTempPhoto() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uplift-test-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]).write(to: url)
        return url.path
    }

    private struct Recorder: @unchecked Sendable {
        let box = Box()
        final class Box: @unchecked Sendable {
            var paths: [String] = []
        }
    }

    /// A session with a scripted server behind it.
    ///
    /// `sleep` is a no-op so a poll loop runs at full speed — the timeout tests
    /// drive the clock instead, which is what keeps them from being slow and
    /// flaky at the same time.
    private func makeSession(
        flow: FunnelFlow,
        reply: @escaping @Sendable (String) -> MockURLProtocol.Reply,
        preflight: InferencePreflight = InferencePreflight(),
        mediaResolver: InferenceMediaResolver? = nil,
        subjectId: String = "subject_1"
    ) throws -> (FlowSession, Recorder) {
        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            recorder.box.paths.append(path)
            return reply(path)
        }
        let client = InferenceClient(config: InferenceClientConfig(
            serverUrl: "https://api.test",
            apiKeyProvider: { "fnl_pk_test" },
            bundleIdProvider: { "com.example.app" },
            urlSession: MockURLProtocol.session()))

        let session = try FlowSession(flow: flow)
        session.flowSlug = "skin_flow"
        session.inference = InferenceEnvironment(
            client: client,
            subjectIdProvider: { subjectId },
            mediaResolver: mediaResolver,
            preflight: preflight,
            policyVersion: "v1",
            sleep: { _ in },
            )
        return (session, recorder)
    }


    /// Wait for the session to leave `analysing`, or fail loudly.
    ///
    /// The failure message is the point: "still on analysing" is exactly what
    /// criterion 4 forbids, so a hang has to read as a hang rather than as a
    /// timeout in an assertion helper.
    private func waitUntilPast(
        _ screenId: String, _ session: FlowSession,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if session.currentScreen.id != screenId || session.completed { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "the flow never left \"\(screenId)\" — criterion 4 says it always moves on",
            file: file, line: line)
    }

    // MARK: - the happy path

    func testAReadyResultWritesTheMappedVariablesAndAdvances() async throws {
        let photo = try writeTempPhoto()
        let (session, recorder) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"cns_1"}"#) }
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.contains("/jobs/") {
                return ok(
                    #"{"status":"SUCCEEDED","outputs":{"skin_type":"combination","score":7.5}}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")   // capture → analysing, auto-starts

        await waitUntilPast("analysing", session)

        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertEqual(session.variables["skin_type"], .string("combination"))
        // The flow declared `score` a number; the model's 7.5 has to arrive as
        // one or every later comparison against it silently fails.
        XCTAssertEqual(session.variables["score"], .number(7.5))
        XCTAssertEqual(session.variables["inference.skin.status"], .string("ready"))
        // The subtree token and the condition variable stay in step.
        XCTAssertEqual(session.variables["inference_skin_status"], .string("ready"))
        XCTAssertTrue(recorder.box.paths.contains("/v1/inference/upload"))
    }

    func testTheStatusTokenIsSeededSoItNeverRendersItsOwnBraces() async throws {
        let (session, _) = try makeSession(flow: try makeFlow()) { _ in
            ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        // Before anything runs. A progress line above the CTA is an ordinary
        // design, and `{{inference.skin.status}}` has to read as a word.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.variables["inference.skin.status"], .string("idle"))
    }

    // MARK: - criterion 4: it always moves on

    func testAServerErrorAppliesTheFallbackAndAdvances() async throws {
        let photo = try writeTempPhoto()
        let (session, _) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"c"}"#) }
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            return .stub(MockURLProtocol.Stub(statusCode: 500, json: #"{"error":"boom"}"#))
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertEqual(session.variables["inference.skin.status"], .string("failed"))
    }

    func testAnUnreachableServerAppliesTheFallbackAndAdvances() async throws {
        let photo = try writeTempPhoto()
        let (session, _) = try makeSession(flow: try makeFlow()) { _ in
            .error(URLError(.notConnectedToInternet))
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
    }

    func testAFailedJobAppliesTheFallbackAndAdvances() async throws {
        let photo = try writeTempPhoto()
        let (session, _) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"c"}"#) }
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.contains("/jobs/") {
                return ok(
                    #"{"status":"FAILED","error_class":"INVALID_INPUT","reason":"rejected"}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertEqual(session.variables["inference.skin.error"], .string("INVALID_INPUT"))
    }

    func testATimeoutAppliesTheFallbackAndAdvances() async throws {
        let photo = try writeTempPhoto()
        // A job that never leaves the queue, and a one-second budget.
        let (session, _) = try makeSession(flow: try makeFlow(timeoutMs: 1_000)) { path in
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"c"}"#) }
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.contains("/jobs/") { return ok(#"{"status":"QUEUED"}"#) }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertEqual(session.variables["inference.skin.error"], .string("timeout"))
    }

    func testNoConsentRecordAppliesTheFallbackRatherThanBlocking() async throws {
        let photo = try writeTempPhoto()
        let (session, _) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"c"}"#) }
            // The server's 403 — the one refusal an author can fix in the flow.
            return .stub(MockURLProtocol.Stub(statusCode: 403, json: #"{"error":"no consent"}"#))
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertEqual(session.variables["inference.skin.error"], .string("consent_required"))
    }

    func testNoEnvironmentAtAllStillAdvances() async throws {
        // An older host, a build with inference unconfigured, a session created
        // outside the facade. The answer arrives immediately rather than after
        // a timeout nobody benefits from.
        let session = try FlowSession(flow: try makeFlow())
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
    }

    // MARK: - the three fallback shapes

    func testGotoFallbackLandsOnTheNamedScreen() async throws {
        let photo = try writeTempPhoto()
        let flow = try makeFlow(fallback: #"{"kind":"goto","screenId":"manual"}"#)
        let (session, _) = try makeSession(flow: flow) { _ in
            .error(URLError(.timedOut))
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "manual")
    }

    func testSetVariablesFallbackWritesThemAndAdvances() async throws {
        let photo = try writeTempPhoto()
        let flow = try makeFlow(
            fallback: #"{"kind":"set_variables","values":{"skin_type":"unknown","score":0}}"#)
        let (session, _) = try makeSession(flow: flow) { _ in
            .error(URLError(.timedOut))
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        // The point of this shape: the rest of the flow was authored against
        // these variables and has something to carry on from.
        XCTAssertEqual(session.variables["skin_type"], .string("unknown"))
        XCTAssertEqual(session.variables["score"], .number(0))
    }

    // MARK: - criterion 9: a rejected photo makes no network call

    func testAPhotoTooSmallNeverReachesTheNetwork() async throws {
        let photo = try writeTempPhoto()
        var preflight = InferencePreflight()
        // The 8-byte fixture cannot pass a 200px floor on any platform that can
        // decode it, and cannot pass the byte ceiling below on one that cannot.
        preflight.minimumDimension = 200
        preflight.maximumBytes = 4

        let (session, recorder) = try makeSession(
            flow: try makeFlow(), reply: { _ in ok("{}") }, preflight: preflight)
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        // Criterion 9, stated as the absence it is: nothing was uploaded and
        // nothing was submitted. The photo did not leave the device.
        XCTAssertFalse(recorder.box.paths.contains("/v1/inference/upload"))
        XCTAssertFalse(recorder.box.paths.contains("/v1/inference/skin"))
    }

    func testAnUnresolvableReferenceNeverReachesTheNetwork() async throws {
        let (session, recorder) = try makeSession(flow: try makeFlow()) { _ in ok("{}") }
        // An asset id in the host's own store, with no resolver registered.
        session.setVariable("selfie", .string("ph-asset://12345"))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.currentScreen.id, "done")
        XCTAssertTrue(recorder.box.paths.isEmpty)
        XCTAssertEqual(session.variables["inference.skin.error"], .string("unreadable_media"))
    }

    func testAHostResolverRescuesAReferenceTheSdkCannotRead() async throws {
        let (session, recorder) = try makeSession(
            flow: try makeFlow(),
            reply: { path in
                if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
                if path.contains("/jobs/") {
                    return ok(#"{"status":"SUCCEEDED","outputs":{"skin_type":"dry"}}"#)
                }
                return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
            },
            mediaResolver: { reference in
                reference == "ph-asset://12345" ? Data([0xFF, 0xD8, 0xFF, 0xE0]) : nil
            })
        session.setVariable("selfie", .string("ph-asset://12345"))
        session.handleAction("next")

        await waitUntilPast("analysing", session)
        XCTAssertEqual(session.variables["skin_type"], .string("dry"))
        XCTAssertTrue(recorder.box.paths.contains("/v1/inference/upload"))
    }

    // MARK: - what the client sends, and what it cannot

    func testTheSubmitCarriesNoModelProviderOrParams() async throws {
        let photo = try writeTempPhoto()
        let (session, _) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.contains("/jobs/") {
                return ok(#"{"status":"SUCCEEDED","outputs":{}}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        session.handleAction("next")
        await waitUntilPast("analysing", session)

        let submit = try XCTUnwrap(MockURLProtocol.recorded.first {
            $0.url?.path == "/v1/inference/skin"
        })
        let body = try XCTUnwrap(submit.bodyJSON?.objectValue)
        // Criterion 4 of spec 04, from the client side: there is no field here
        // that could steer a credentialed request. The server reads the model
        // and the provider off the app's own binding.
        XCTAssertNil(body["model"])
        XCTAssertNil(body["provider"])
        XCTAssertNil(body["params"])
        XCTAssertEqual(body["flow_slug"], .string("skin_flow"))
        XCTAssertEqual(submit.header("X-Uplift-Subject-Id"), "subject_1")
        XCTAssertEqual(submit.header("Authorization"), "Bearer fnl_pk_test")
    }

    func testConsentIsRecordedBeforeTheJobStarts() async throws {
        let photo = try writeTempPhoto()
        let (session, recorder) = try makeSession(flow: try makeFlow()) { path in
            if path.hasSuffix("/consent") { return ok(#"{"consent_id":"cns_1"}"#) }
            if path.hasSuffix("/upload") { return ok(#"{"upload_id":"mup_1"}"#) }
            if path.contains("/jobs/") {
                return ok(#"{"status":"SUCCEEDED","outputs":{}}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        // The CTA that consents is the CTA that starts the job, on the screen
        // that just said where the photo goes — App Store 5.1.2(i) wants
        // permission before transmission, and this is the shape of it.
        session.handleAction("consent:skin")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(recorder.box.paths.contains("/v1/inference/consent"))
        let consent = try XCTUnwrap(MockURLProtocol.recorded.first {
            $0.url?.path == "/v1/inference/consent"
        })
        let body = try XCTUnwrap(consent.bodyJSON?.objectValue)
        XCTAssertEqual(body["purpose"], .string("image_analysis"))
        XCTAssertEqual(body["policy_version"], .string("v1"))
        // No provider and no model, because the client does not know them and
        // must not: they live in the app's binding, which is what keeps a flow
        // document from naming the vendor that receives a photo. The server
        // resolves them and records the name it will actually send to.
        //
        // Sending empty strings — which this did until a simulator round found
        // it — made the server reject every grant with a 400, so consent was
        // silently never recorded and every inference then 403'd.
        XCTAssertNil(body["provider"])
        XCTAssertNil(body["model"])
    }

    func testADoubleTapStartsOneJob() async throws {
        let photo = try writeTempPhoto()
        let (session, recorder) = try makeSession(flow: try makeFlow(photoInput: false)) { path in
            if path.contains("/jobs/") {
                return ok(#"{"status":"SUCCEEDED","outputs":{"skin_type":"oily"}}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("selfie", .string(photo))
        // A bare FlowSession does not seed declared defaults — the facade does
        // that — so the variable input this flow reads has to be set here.
        session.setVariable("goal", .string("clear"))
        session.handleAction("infer:skin")
        session.handleAction("infer:skin")
        await waitUntilPast("capture", session)

        let submits = recorder.box.paths.filter { $0 == "/v1/inference/skin" }
        // The server would deduplicate anyway, but two in-flight runs would
        // race to write the same variables and the loser would win at random.
        // The count is also 1 rather than 2 because arriving at the loading
        // screen must not re-run what the button already started.
        XCTAssertEqual(submits.count, 1)
    }

    func testAResultThatArrivesAfterTheUserMovedOnDoesNotSkipAScreen() async throws {
        // `["infer:skin", "next"]` on one button: the tap starts the job and
        // then advances, and the job finishes later. Advancing again from the
        // completion handler would skip a screen nobody saw.
        let (session, _) = try makeSession(flow: try makeFlow(photoInput: false)) { path in
            if path.contains("/jobs/") {
                return ok(#"{"status":"SUCCEEDED","outputs":{"skin_type":"oily"}}"#)
            }
            return ok(#"{"job_id":"inf_1","poll_after_ms":10}"#)
        }
        session.setVariable("goal", .string("clear"))
        session.handleAction("infer:skin")
        session.handleAction("next")          // capture → analysing, immediately
        XCTAssertEqual(session.currentScreen.id, "analysing")

        try? await Task.sleep(nanoseconds: 120_000_000)

        // The answer still landed — it is about the person, not about where
        // they are standing — but the flow stayed put.
        XCTAssertEqual(session.variables["skin_type"], .string("oily"))
        XCTAssertEqual(session.currentScreen.id, "analysing")
    }

    // MARK: - decoding

    func testAnAspectWithNoFallbackIsDeclinedRatherThanRun() {
        // I30's shape. A build that half-understands an aspect and runs it
        // anyway is worse than one that declines and lets the flow carry on.
        let raw: [String: Any] = [
            "id": "skin", "capability": "image_analysis",
            "inputs": [:], "outputs": [:], "timeout_ms": 5_000,
        ]
        XCTAssertNil(InferenceSpec.decode(raw))
    }

    func testAnUnknownInputKindIsSkippedNotSentEmpty() {
        let raw: [String: Any] = [
            "id": "skin", "capability": "image_analysis",
            "inputs": [
                "a": ["kind": "variable", "name": "goal"],
                "b": ["kind": "profile", "key": "category"],
                "c": ["kind": "something_new", "name": "x"],
            ],
            "outputs": [:], "timeout_ms": 5_000,
            "fallback": ["kind": "skip"],
        ]
        let spec = InferenceSpec.decode(raw)
        XCTAssertEqual(spec?.variableInputs, ["a": "goal"])
        // An empty field reads to a model as an answer, and it is not one.
        XCTAssertEqual(spec?.photoInputs, [:])
    }

    func testTheThreeFallbackShapesDecode() {
        XCTAssertEqual(InferenceFallback.decode(["kind": "skip"]), .skip)
        XCTAssertEqual(
            InferenceFallback.decode(["kind": "goto", "screenId": "manual"]),
            .goto(screenId: "manual"))
        XCTAssertEqual(
            InferenceFallback.decode(["kind": "set_variables", "values": ["a": "b"]]),
            .setVariables(["a": .string("b")]))
        XCTAssertNil(InferenceFallback.decode(["kind": "teleport"]))
        XCTAssertNil(InferenceFallback.decode(nil))
    }

    // MARK: - media

    func testLocalReferencesTheSdkReadsWithoutAsking() throws {
        let path = try writeTempPhoto()
        XCTAssertNotNil(InferenceMedia.resolveLocally(path))
        XCTAssertNotNil(InferenceMedia.resolveLocally("file://\(path)"))
        XCTAssertNotNil(
            InferenceMedia.resolveLocally("data:image/png;base64,iVBORw0KGgo="))
        // An https URL is deliberately not read: fetching one would make the
        // SDK a downloader of arbitrary hosts on a path that then uploads what
        // it got, and the host knows whether its own URL is safe.
        XCTAssertNil(InferenceMedia.resolveLocally("https://cdn.example.com/a.jpg"))
        XCTAssertNil(InferenceMedia.resolveLocally("ph-asset://12345"))
    }

    func testContentTypeGuessesJpegRatherThanOctetStream() {
        XCTAssertEqual(InferenceMedia.contentType(forPath: "png"), "image/png")
        XCTAssertEqual(InferenceMedia.contentType(forPath: "HEIC"), "image/heic")
        XCTAssertEqual(InferenceMedia.contentType(forPath: "m4a"), "audio/m4a")
        // The server refuses octet-stream outright, so a wrong guess here is a
        // 415 rather than a best effort.
        XCTAssertEqual(InferenceMedia.contentType(forPath: "xyz"), "image/jpeg")
    }

    func testFaceDetectionIsOffByDefault() {
        // Nothing in a flow document says "expect a face here", and a meal
        // photo sent for calorie estimation is a legitimate `image_analysis`
        // that a face check would refuse.
        XCTAssertFalse(InferencePreflight().requiresFace)
    }

    func testAudioSkipsThePixelChecks() {
        let clip = ResolvedMedia(data: Data(count: 1_024), contentType: "audio/m4a")
        guard case .pass = InferencePreflight().apply(clip) else {
            return XCTFail("an audio clip must not be judged by an image heuristic")
        }
    }

    // MARK: - criterion 1: the render pipeline does not learn about inference

    /// Spec 15 criterion 1: no item of that spec changes the render pipeline.
    ///
    /// Checked by reading source rather than by exercising behaviour, because
    /// that is what the rule is about — the number of places that *know*. The
    /// renderer is matched byte for byte by two other implementations
    /// (PrimitiveRenderer.tsx and the Flutter engine), so a namespace learned
    /// here silently makes three codebases disagree.
    ///
    /// This is why `infer:` is caught in `FlowSession` next to `go:` and `set:`
    /// rather than in `PrimitiveScreenHost` where `permission:` lives, and why
    /// `{{inference.<id>.*}}` is a flat session variable rather than a scoped
    /// namespace like `{{product.*}}`.
    func testTheRenderLayerNamesNothingAboutInference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UpliftFunnelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources")

        var scanned = 0
        var offenders: [String] = []
        for directory in ["UpliftFunnel/Render", "UpliftLayout"] {
            let base = root.appendingPathComponent(directory)
            let files = try FileManager.default.subpathsOfDirectory(atPath: base.path)
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let text = try String(
                    contentsOf: base.appendingPathComponent(file), encoding: .utf8)
                scanned += 1
                for needle in ["infer:", "inference", "Inference", "consent:"] {
                    if text.contains(needle) {
                        offenders.append("\(directory)/\(file): \(needle)")
                    }
                }
            }
        }
        // A path change that made this scan nothing would otherwise pass.
        XCTAssertGreaterThan(scanned, 10, "the scan found no render sources")
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }
}

/// A 200 with a JSON body. Free function rather than a method so the scripted
/// handlers — which run off the main actor, inside URLProtocol — can call it.
private func ok(_ json: String) -> MockURLProtocol.Reply {
    .stub(MockURLProtocol.Stub(statusCode: 200, json: json))
}
