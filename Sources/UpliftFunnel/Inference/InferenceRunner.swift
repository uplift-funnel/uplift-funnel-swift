import Foundation

// One inference, from the tap to the variables.
//
// ── The rule this file exists to hold ───────────────────────────────────────
//
// Spec 15 criterion 4: `infer:` applies the fallback and the flow moves on —
// **it never hangs**. Every path out of `run` ends in either an outcome or a
// fallback, there is no `return` that leaves the flow where it was, and the
// deadline is checked between every poll. A user staring at a spinner that
// outlives the number the author wrote is the failure this is written against,
// and it is a failure that only shows up on a bad network in someone else's
// country.
//
// ── Where the status token comes from ───────────────────────────────────────
//
// `{{inference.<id>.status}}` is an ordinary flat session variable, seeded at
// flow start and rewritten on every transition. It is NOT scoped to the subtree
// carrying the aspect the way `{{product.*}}` is, and the reason is criterion 1:
// scoping is a renderer concept, and no item of spec 15 may change the render
// pipeline. Flat is safe here because an inference id is unique flow-wide.

/// The phase a waiting screen draws from.
enum InferenceStatus: String, Sendable {
    /// Declared, never started. Seeded at flow start so the token never renders
    /// as literal braces on a screen the user reaches before the job.
    case idle
    case pending
    case ready
    case failed
}

/// What the engine needs from the outside to run one. Injected rather than
/// reached for, so the whole lifecycle is testable without a network.
struct InferenceEnvironment: Sendable {
    let client: InferenceClient
    let subjectIdProvider: @Sendable () -> String
    let mediaResolver: InferenceMediaResolver?
    let preflight: InferencePreflight
    /// The consent text version the customer shipped. Recorded with the grant,
    /// so a later change to that text is visible as a different version rather
    /// than silently covered by an old agreement.
    let policyVersion: String
    /// Injected for tests; production passes `Task.sleep`.
    let sleep: @Sendable (UInt64) async -> Void
}

/// What became of one run. The caller turns this into variables and navigation.
enum InferenceOutcome: Sendable {
    case ready(outputs: [String: JSONValue])
    /// `code` reaches `{{inference.<id>.error}}`; it is a class, never a
    /// provider's sentence.
    case failed(code: String, message: String)
}

/// The parts of `behavior.inference` the runner needs, lifted out of the raw
/// document once so the loop below is not re-parsing JSON on every poll.
struct InferenceSpec: Sendable {
    let id: String
    let capability: String
    /// Input name → the variable holding its value.
    let variableInputs: [String: String]
    /// Input name → the variable holding a photo reference.
    let photoInputs: [String: String]
    let timeoutMs: Int
    let requiresConsent: Bool
    let fallback: InferenceFallback

    /// Decode from the flow document's node dictionary, or nil when the shape
    /// is not one this SDK version understands.
    ///
    /// Returning nil rather than a partly-filled spec is I30's shape: a build
    /// that half-understands an aspect and runs it anyway is worse than one
    /// that declines and lets the flow carry on without it.
    static func decode(_ raw: [String: Any]) -> InferenceSpec? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let capability = raw["capability"] as? String,
              let fallback = InferenceFallback.decode(raw["fallback"])
        else { return nil }

        var variableInputs: [String: String] = [:]
        var photoInputs: [String: String] = [:]
        if let inputs = raw["inputs"] as? [String: Any] {
            for (name, role) in inputs {
                guard let role = role as? [String: Any],
                      let kind = role["kind"] as? String else { continue }
                switch kind {
                case "variable":
                    if let source = role["name"] as? String { variableInputs[name] = source }
                case "photo":
                    if let source = role["name"] as? String { photoInputs[name] = source }
                default:
                    // `profile` is resolved server-side, and an unknown kind is
                    // a newer document than this build. Skipping beats sending
                    // an empty field, which reads to a model as an answer.
                    continue
                }
            }
        }

        return InferenceSpec(
            id: id,
            capability: capability,
            variableInputs: variableInputs,
            photoInputs: photoInputs,
            timeoutMs: (raw["timeout_ms"] as? NSNumber)?.intValue ?? 30_000,
            requiresConsent: (raw["requires_consent"] as? Bool) ?? false,
            fallback: fallback)
    }
}

/// What the flow does when the model does not answer.
enum InferenceFallback: Sendable, Equatable {
    case skip
    case goto(screenId: String)
    case setVariables([String: JSONValue])

    static func decode(_ raw: Any?) -> InferenceFallback? {
        guard let raw = raw as? [String: Any], let kind = raw["kind"] as? String else {
            // Required by the schema, so absent means either a document this
            // build should not be running or one that never validated. Either
            // way the honest answer is "this aspect is not usable".
            return nil
        }
        switch kind {
        case "skip":
            return .skip
        case "goto":
            guard let screenId = raw["screenId"] as? String else { return nil }
            return .goto(screenId: screenId)
        case "set_variables":
            guard let values = raw["values"] as? [String: Any] else { return nil }
            var decoded: [String: JSONValue] = [:]
            for (name, value) in values { decoded[name] = JSONValue(any: value) }
            return .setVariables(decoded)
        default:
            return nil
        }
    }
}

enum InferenceRunner {
    /// The whole lifecycle: resolve inputs, pre-filter, upload, submit, poll.
    ///
    /// Never throws and never returns without an answer.
    static func run(
        spec: InferenceSpec,
        flowSlug: String,
        sessionId: String,
        variables: [String: JSONValue],
        environment: InferenceEnvironment,
        now: @Sendable () -> Date = { Date() }
    ) async -> InferenceOutcome {
        let subjectId = environment.subjectIdProvider()
        guard !subjectId.isEmpty else {
            return .failed(code: "not_configured", message: "No subject for this session.")
        }

        let deadline = now().addingTimeInterval(Double(spec.timeoutMs) / 1000)

        var inputs: [String: JSONValue] = [:]
        for (name, source) in spec.variableInputs {
            guard let value = variables[source], !value.isNull else {
                return .failed(
                    code: "missing_input",
                    message: "The flow has not collected \"\(source)\" yet.")
            }
            inputs[name] = value
        }

        // Photos: resolve, pre-filter, upload. Criterion 9 lives in the order —
        // a photo that fails the filter has not reached `upload`, so no network
        // call is made at all.
        for (name, source) in spec.photoInputs {
            guard let reference = variables[source]?.stringValue, !reference.isEmpty else {
                return .failed(
                    code: "missing_input",
                    message: "No photo was chosen for \"\(source)\".")
            }
            guard let media = await resolveMedia(reference, environment: environment) else {
                return .failed(
                    code: "unreadable_media",
                    message: "That photo could not be read.")
            }
            switch environment.preflight.apply(media) {
            case .reject(let failure):
                return .failed(code: failure.code, message: failure.message)
            case .pass(let prepared):
                guard let uploadId = await environment.client.upload(
                    subjectId: subjectId,
                    contentType: prepared.contentType,
                    body: prepared.data)
                else {
                    return .failed(code: "upload_failed", message: "The photo could not be sent.")
                }
                inputs[name] = .string(uploadId)
            }
        }

        let submission = await environment.client.submit(
            inferenceId: spec.id, subjectId: subjectId, sessionId: sessionId,
            flowSlug: flowSlug, inputs: inputs)

        guard case .accepted(let jobId, let pollAfterMs) = submission else {
            guard case .refused(let reason) = submission else {
                return .failed(code: "unknown", message: "The inference did not start.")
            }
            return .failed(code: reason.rawValue, message: message(for: reason))
        }

        return await poll(
            jobId: jobId, subjectId: subjectId, firstDelayMs: pollAfterMs,
            deadline: deadline, environment: environment, now: now)
    }

    /// Record consent, for the `consent:<id>` action.
    static func recordConsent(
        spec: InferenceSpec, environment: InferenceEnvironment
    ) async -> Bool {
        let subjectId = environment.subjectIdProvider()
        guard !subjectId.isEmpty else { return false }
        // The provider and model are the server's to know — it reads them off
        // the app's binding, the same row the submit will resolve. The client
        // sends what it has: which capability, and which version of the text
        // the person just read.
        return await environment.client.recordConsent(
            subjectId: subjectId,
            purpose: spec.capability,
            policyVersion: environment.policyVersion)
    }

    // MARK: - Private

    private static func resolveMedia(
        _ reference: String, environment: InferenceEnvironment
    ) async -> ResolvedMedia? {
        // Local first: a file URL is what every picker on this platform returns,
        // and asking a host to resolve one it did not have to think about is an
        // integration step charged for nothing.
        if let local = InferenceMedia.resolveLocally(reference) { return local }
        guard let resolver = environment.mediaResolver,
              let data = await resolver(reference) else { return nil }
        // The host handed back bytes and no type. jpeg is the honest guess —
        // it is what a camera roll is full of, and the server refuses
        // octet-stream outright.
        return ResolvedMedia(data: data, contentType: "image/jpeg")
    }

    /// Poll until terminal or out of time.
    ///
    /// The delay starts at the server's `poll_after_ms` and grows by half each
    /// time, capped: a job that takes twenty seconds should not be asked about
    /// forty times, and one that takes one second should not wait five.
    private static func poll(
        jobId: String, subjectId: String, firstDelayMs: Int, deadline: Date,
        environment: InferenceEnvironment, now: @Sendable () -> Date
    ) async -> InferenceOutcome {
        var delayMs = max(firstDelayMs, 100)
        let maxDelayMs = 4_000

        while true {
            // Before the sleep, not after: a deadline that has already passed
            // should not buy the job one more second.
            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0 {
                return .failed(
                    code: "timeout",
                    message: "The analysis took too long. Carrying on without it.")
            }
            // Never sleep past the deadline — that would turn a 15-second
            // timeout into 15 seconds plus one poll interval.
            let sleepMs = min(Double(delayMs), remaining * 1000)
            await environment.sleep(UInt64(max(sleepMs, 0) * 1_000_000))

            switch await environment.client.poll(jobId: jobId, subjectId: subjectId) {
            case .succeeded(let outputs):
                return .ready(outputs: outputs)
            case .failed(let errorClass, let reason):
                return .failed(code: errorClass, message: reason)
            case .queued, .running:
                delayMs = min(delayMs + delayMs / 2, maxDelayMs)
            }
        }
    }

    private static func message(for reason: InferenceRefusal) -> String {
        switch reason {
        case .consentRequired:
            return "The user has not agreed to this analysis."
        case .notConfigured:
            return "No provider is connected for this capability."
        case .badRequest:
            return "The inference request was rejected."
        case .unreachable:
            return "The server could not be reached."
        }
    }
}
