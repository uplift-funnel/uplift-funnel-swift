import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The four calls the inference surface makes.
//
// Same shape as `TriggerClient` and separate from `FlowFetcher` for the same
// reason: that one is a cache-first reader of documents with ETags, and none of
// it applies to a job that exists for thirty seconds.
//
// What is NOT here, and deliberately: a model name, a provider, a parameter.
// The server reads all three from the flow document and the app's binding
// (spec 04 criterion 4), so there is no field on any of these requests that
// could carry one. A tampered client can start an inference its own flow
// already publishes, with inputs its own user could have typed.

struct InferenceClientConfig: Sendable {
    let serverUrl: String
    let apiKeyProvider: @Sendable () -> String
    let bundleIdProvider: @Sendable () -> String?
    let urlSession: URLSession
    /// Generous next to the trigger client's six seconds: an upload carries a
    /// photo, and a user who just tapped "Analyse" is watching a spinner they
    /// expect to take a moment.
    var timeout: TimeInterval = 30
}

/// Where a job is, in the client's vocabulary.
enum InferenceJobState: Sendable, Equatable {
    case queued
    case running
    case succeeded(outputs: [String: JSONValue])
    /// `reason` is the server's short, device-safe sentence — never a vendor
    /// error body, which is written for an operator and is the one place a
    /// stray credential echo could reach a phone.
    case failed(errorClass: String, reason: String)

    var isTerminal: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed: return true
        }
    }
}

/// What a submit answered.
enum InferenceSubmission: Sendable {
    case accepted(jobId: String, pollAfterMs: Int)
    /// The call was refused and no job exists. `consentRequired` is its own
    /// case because it is the only one an author can fix in the flow.
    case refused(reason: InferenceRefusal)
}

enum InferenceRefusal: String, Sendable {
    case consentRequired = "consent_required"
    case notConfigured = "not_configured"
    case badRequest = "bad_request"
    case unreachable = "unreachable"
}

struct InferenceClient: Sendable {
    let config: InferenceClientConfig

    /// Record that the user agreed to what a screen just described.
    ///
    /// Fire-and-forget would be wrong here — the very next thing that happens
    /// is a submit that the server refuses without this row, so the caller
    /// waits and learns whether it landed.
    func recordConsent(
        subjectId: String, purpose: String, policyVersion: String
    ) async -> Bool {
        guard let url = URL(string: "\(config.serverUrl)/v1/inference/consent") else {
            return false
        }
        // No provider and no model, because the client does not know them and
        // must not: they live in the app's binding, server-side, precisely so a
        // flow document cannot name the vendor that receives a photo. The
        // server fills them in from the binding and records the name it will
        // actually send to.
        let body: [String: JSONValue] = [
            "purpose": .string(purpose),
            "policy_version": .string(policyVersion),
        ]
        guard let data = try? JSONValue.object(body).serializedData() else { return false }
        var request = makeRequest(url: url, subjectId: subjectId, method: "POST")
        request.httpBody = data
        guard let (_, response) = try? await config.urlSession.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Send the bytes. Returns the upload id the submit refers to them by.
    ///
    /// The response is an id and an expiry, never a URL: the server holds the
    /// image for at most an hour and hands it to the model inline, so no public
    /// address for a user's face is ever minted.
    func upload(subjectId: String, contentType: String, body: Data) async -> String? {
        guard let url = URL(string: "\(config.serverUrl)/v1/inference/upload") else {
            return nil
        }
        var request = makeRequest(url: url, subjectId: subjectId, method: "POST")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let (payload, response) = try? await config.urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONValue.parse(payload),
              case .object(let fields) = json,
              case .string(let id)? = fields["upload_id"]
        else { return nil }
        return id
    }

    /// Start the job.
    func submit(
        inferenceId: String, subjectId: String, sessionId: String, flowSlug: String,
        inputs: [String: JSONValue]
    ) async -> InferenceSubmission {
        guard let url = URL(string: "\(config.serverUrl)/v1/inference/\(inferenceId)") else {
            return .refused(reason: .badRequest)
        }
        let body: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "flow_slug": .string(flowSlug),
            "inputs": .object(inputs),
        ]
        guard let data = try? JSONValue.object(body).serializedData() else {
            return .refused(reason: .badRequest)
        }
        var request = makeRequest(url: url, subjectId: subjectId, method: "POST")
        request.httpBody = data

        guard let (payload, response) = try? await config.urlSession.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .refused(reason: .unreachable) }

        if http.statusCode == 403 { return .refused(reason: .consentRequired) }
        // 409 is the server saying the app has no binding, or a photo capability
        // with no pinned release — a setup problem, not a user problem, and not
        // one a retry fixes.
        if http.statusCode == 409 { return .refused(reason: .notConfigured) }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONValue.parse(payload),
              case .object(let fields) = json,
              case .string(let jobId)? = fields["job_id"]
        else {
            return .refused(reason: http.statusCode >= 500 ? .unreachable : .badRequest)
        }
        var pollAfter = 800
        if case .number(let ms)? = fields["poll_after_ms"] { pollAfter = Int(ms) }
        return .accepted(jobId: jobId, pollAfterMs: pollAfter)
    }

    /// Ask where a job is. A request that fails answers `.running` rather than
    /// `.failed`: one unreachable poll says nothing about the job, and the
    /// caller's own deadline is what ends the wait.
    func poll(jobId: String, subjectId: String) async -> InferenceJobState {
        guard let url = URL(string: "\(config.serverUrl)/v1/inference/jobs/\(jobId)") else {
            return .failed(errorClass: "bad_request", reason: "The job id is unusable.")
        }
        let request = makeRequest(url: url, subjectId: subjectId, method: "GET")

        guard let (payload, response) = try? await config.urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONValue.parse(payload),
              case .object(let fields) = json,
              case .string(let status)? = fields["status"]
        else { return .running }

        switch status {
        case "SUCCEEDED":
            var outputs: [String: JSONValue] = [:]
            if case .object(let mapped)? = fields["outputs"] { outputs = mapped }
            return .succeeded(outputs: outputs)
        case "FAILED", "CANCELED", "EXPIRED":
            var errorClass = status
            if case .string(let cls)? = fields["error_class"] { errorClass = cls }
            var reason = "The inference did not complete."
            if case .string(let text)? = fields["reason"] { reason = text }
            return .failed(errorClass: errorClass, reason: reason)
        case "RUNNING":
            return .running
        default:
            return .queued
        }
    }

    // MARK: - Private

    private func makeRequest(url: URL, subjectId: String, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = config.apiKeyProvider()
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(subjectId, forHTTPHeaderField: "X-Uplift-Subject-Id")
        if let bundleId = config.bundleIdProvider(), !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Uplift-Bundle-Id")
        }
        return request
    }
}
