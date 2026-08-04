import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The two calls the trigger surface makes.
//
// Deliberately not part of `FlowFetcher`: that one is a cache-first reader of
// documents with ETags and background revalidation, and none of that applies
// here. An evaluation is a question about *now* — caching it would answer with
// a decision the frequency rules have already spent.

struct TriggerClientConfig: Sendable {
    let serverUrl: String
    let apiKeyProvider: @Sendable () -> String
    let bundleIdProvider: @Sendable () -> String?
    let urlSession: URLSession
    /// Short: this runs on app foreground, and a user who waits ten seconds for
    /// a banner has already started doing something else.
    var timeout: TimeInterval = 6
}

/// What the client tells the server about where it is.
struct TriggerEvaluateRequest: Sendable {
    let subjectId: String
    let sessionId: String
    /// Events fired but not yet uploaded, so a trigger can fire on the thing
    /// that just happened rather than on the next foreground.
    let recentEvents: [(name: String, at: Date)]
    /// Flow slugs on screen right now, for `suppressIfFlowActive`.
    let activeFlows: [String]
}

struct TriggerClient: Sendable {
    let config: TriggerClientConfig

    /// Ask what to show. Never throws: a trigger surface that can fail is a
    /// surface that takes an app launch down with it, and the honest answer to
    /// an unreachable server is "nothing fired".
    func evaluate(_ request: TriggerEvaluateRequest) async -> TriggerEvaluation {
        guard let url = URL(string: "\(config.serverUrl)/v1/triggers/evaluate") else {
            return .empty
        }
        var body: [String: JSONValue] = [
            "session_id": .string(request.sessionId),
            "context": .object(contextFields()),
        ]
        if !request.recentEvents.isEmpty {
            body["recent_events"] = .array(request.recentEvents.map { event in
                .object([
                    "event_type": .string(event.name),
                    "timestamp": .number(event.at.timeIntervalSince1970 * 1000),
                ])
            })
        }
        if !request.activeFlows.isEmpty {
            body["active_flows"] = .array(request.activeFlows.map { .string($0) })
        }

        guard let data = try? JSONValue.object(body).serializedData() else { return .empty }
        var urlRequest = makeRequest(url: url, subjectId: request.subjectId)
        urlRequest.httpBody = data

        guard let (payload, response) = try? await config.urlSession.data(for: urlRequest),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONValue.parse(payload)
        else { return .empty }

        return TriggerEvaluation.decode(json)
    }

    /// Report what became of a decision. Fire-and-forget, like `identify`.
    func report(
        triggerId: String, subjectId: String, sessionId: String,
        outcome: String, reason: UnpresentableReason? = nil
    ) async {
        guard let url = URL(string: "\(config.serverUrl)/v1/triggers/outcome") else { return }
        var body: [String: JSONValue] = [
            "trigger_id": .string(triggerId),
            "subject_id": .string(subjectId),
            "session_id": .string(sessionId),
            "outcome": .string(outcome),
        ]
        if let reason { body["reason"] = .string(reason.rawValue) }
        guard let data = try? JSONValue.object(body).serializedData() else { return }

        var urlRequest = makeRequest(url: url, subjectId: subjectId)
        urlRequest.httpBody = data
        _ = try? await config.urlSession.data(for: urlRequest)
    }

    // MARK: - Private

    private func makeRequest(url: URL, subjectId: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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

    /// What the server needs about this device that it cannot know.
    ///
    /// `tz_offset_minutes` is the load-bearing one: quiet hours are expressed
    /// in the user's local time and there is no timezone on the server, so a
    /// build that does not send this has quiet hours silently not applied.
    private func contextFields() -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "tz_offset_minutes": .number(Double(TimeZone.current.secondsFromGMT() / 60)),
            "platform": .string(DeviceContext.platform),
            "sdk_version": .string(kUpliftFunnelSdkVersion),
        ]
        if let locale = DeviceContext.localeTag, !locale.isEmpty {
            fields["locale"] = .string(locale)
        }
        return fields
    }
}
