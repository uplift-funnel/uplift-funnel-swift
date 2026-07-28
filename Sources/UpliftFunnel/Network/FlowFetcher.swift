import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// HTTP fetcher for flow JSON with ETag-aware revalidation against a
// FlowCache, ported from the Flutter SDK's `network/flow_fetcher.dart`.
//
//   1. Read the cached entry (if any). Return immediately so the caller can
//      render with no network wait.
//   2. In parallel, fire a conditional GET (`If-None-Match: <etag>`).
//      - 304 Not Modified → keep using cached entry.
//      - 200 OK           → update the cache.
//      - Network error    → keep cached.

public struct FetchedFlow: Sendable {
    public let json: String
    public let source: FetchSource
    public let etag: String?

    /// Published flow version from the `X-Uplift-Flow-Version` response
    /// header (present on 200 and 304), or the cached value on a warm-cache
    /// hit. Nil when served by a pre-analytics API.
    public let flowVersion: Int?

    /// Server-side A/B routing decision from the `X-Uplift-Experiment` +
    /// `X-Uplift-Variant-Name` response headers. Nil on the instant
    /// cache-hit path (the caller falls back to the persisted assignment).
    public let experimentAssignment: UpliftFunnelExperimentAssignment?

    init(
        json: String, source: FetchSource, etag: String?,
        flowVersion: Int? = nil,
        experimentAssignment: UpliftFunnelExperimentAssignment? = nil
    ) {
        self.json = json
        self.source = source
        self.etag = etag
        self.flowVersion = flowVersion
        self.experimentAssignment = experimentAssignment
    }
}

public enum FetchSource: String, Sendable {
    case cache
    case network
    case cacheRevalidated
}

/// Typed fetch failure. Thrown only when there's no cache to fall back to.
/// The message is written to be shown directly to developers; the SDK never
/// parses or surfaces error response bodies.
public struct FlowFetchError: Error, LocalizedError, Sendable {
    /// Category, mapped straight from HTTP status (or the absence of a
    /// response) — never from parsing the error body, so a non-JSON error
    /// page can't crash the SDK.
    public enum Kind: Sendable {
        /// 404 — the flow/experiment key doesn't exist or isn't published.
        case notFound
        /// 401 — the API key is missing or invalid.
        case unauthorized
        /// 403 — the API key is valid but not allowed to fetch this resource.
        case forbidden
        /// No response reached the SDK at all (offline, DNS, timeout).
        case network
        /// A 2xx response came back but the body wasn't valid flow JSON.
        case invalidPayload
        /// Any other non-2xx status (5xx, unexpected 4xx).
        case server
    }

    public let kind: Kind
    /// The flow/experiment key that was being fetched when this failed.
    public let flowKey: String
    /// HTTP status code, when one was received (nil for `.network`).
    public let statusCode: Int?
    let message: String?

    init(kind: Kind, flowKey: String, statusCode: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.flowKey = flowKey
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? {
        let detail: String
        switch kind {
        case .notFound:
            detail = "Flow '\(flowKey)' is not published (404). Check the key "
                + "and that the flow has a live version."
        case .unauthorized:
            detail = "Invalid or missing API key (401). Check the apiKey "
                + "passed to UpliftFunnel.configure."
        case .forbidden:
            detail = "This API key can't access '\(flowKey)' (403)."
        case .network:
            detail = "Couldn't reach the Uplift Funnel server while fetching "
                + "'\(flowKey)', and no cached copy was available."
        case .invalidPayload:
            detail = "Flow '\(flowKey)' returned a response that isn't valid flow JSON."
        case .server:
            let status = statusCode.map { " (HTTP \($0))" } ?? ""
            detail = "Uplift Funnel server error fetching '\(flowKey)'\(status)."
        }
        return "FlowFetchException: \(detail)\(message.map { " (\($0))" } ?? "")"
    }
}

public final class FlowFetcher: @unchecked Sendable {
    let cache: FlowCache
    private let session: URLSession
    private let timeout: TimeInterval

    /// Builds the URLSession all SDK requests go through: ephemeral and with
    /// URLCache disabled, so URLSession's transparent conditional-GET cache
    /// can never hide the 304s our manual ETag flow branches on. Redirects are
    /// refused so a 3xx can't forward the API key to another host — see
    /// `NoRedirectDelegate`.
    static func makeSession(timeout: TimeInterval = 8) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        return URLSession(
            configuration: config,
            delegate: NoRedirectDelegate.shared,
            delegateQueue: nil)
    }

    public init(
        cache: FlowCache,
        urlSession: URLSession? = nil,
        timeout: TimeInterval = 8
    ) {
        self.cache = cache
        self.timeout = timeout
        self.session = urlSession ?? Self.makeSession(timeout: timeout)
    }

    /// Fetch a flow with cache-first behavior.
    ///
    /// **Hot-cache fast path** (default): if a cached entry exists and
    /// `forceRefresh` is false, returns that entry instantly with
    /// `FetchSource.cache` and fires a background conditional GET that
    /// updates the cache for next launch.
    ///
    /// **Cold-cache / forced** path: awaits the network, falls back to any
    /// cached copy on transport error, otherwise throws `FlowFetchError`.
    ///
    /// `onAssignment` fires whenever the server reports an assignment on a
    /// 200/304 — including from the background revalidation, which is how a
    /// warm-cache start learns/updates its persisted assignment.
    public func fetch(
        url: URL,
        flowId: String,
        apiKey: String?,
        subjectId: String? = nil,
        bundleId: String? = nil,
        forceRefresh: Bool = false,
        onAssignment: (@Sendable (UpliftFunnelExperimentAssignment) -> Void)? = nil
    ) async throws -> FetchedFlow {
        let cached = forceRefresh ? nil : cache.read(flowId: flowId)

        // Hot-cache fast path: return immediately, revalidate in the
        // background. Errors there are swallowed — they must never surface.
        if !forceRefresh, let cached {
            Task { [weak self] in
                await self?.revalidateInBackground(
                    url: url, flowId: flowId, apiKey: apiKey,
                    subjectId: subjectId, bundleId: bundleId, cached: cached,
                    onAssignment: onAssignment)
            }
            return FetchedFlow(
                json: cached.json, source: .cache, etag: cached.etag,
                flowVersion: cached.version)
        }

        return try await fetchAwaiting(
            url: url, flowId: flowId, apiKey: apiKey, subjectId: subjectId,
            bundleId: bundleId, cached: cached, onAssignment: onAssignment)
    }

    // MARK: - Private

    private func makeRequest(
        url: URL, apiKey: String?, etag: String?, subjectId: String?,
        bundleId: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let subjectId, !subjectId.isEmpty {
            request.setValue(subjectId, forHTTPHeaderField: "X-Uplift-Subject-Id")
        }
        if let bundleId, !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Uplift-Bundle-Id")
        }
        return request
    }

    private func fetchAwaiting(
        url: URL, flowId: String, apiKey: String?, subjectId: String?,
        bundleId: String?, cached: CachedFlow?,
        onAssignment: (@Sendable (UpliftFunnelExperimentAssignment) -> Void)?
    ) async throws -> FetchedFlow {
        let request = makeRequest(
            url: url, apiKey: apiKey, etag: cached?.etag, subjectId: subjectId,
            bundleId: bundleId)

        let data: Data
        let response: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: request)
            guard let http = r as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            data = d
            response = http
        } catch {
            // Network error / timeout — no response reached us at all. Fall
            // back to cache silently if available.
            if let cached {
                return FetchedFlow(
                    json: cached.json, source: .cache, etag: cached.etag,
                    flowVersion: cached.version)
            }
            throw FlowFetchError(
                kind: .network, flowKey: flowId, message: "\(error)")
        }

        // Status is checked BEFORE any parsing of the body — an error page
        // (HTML, plaintext, whatever) must never be cast as flow JSON.
        let assignment = UpliftFunnelExperimentAssignment.fromHeaders(
            experimentHeader: response.value(forHTTPHeaderField: "X-Uplift-Experiment"),
            variantNameHeader: response.value(forHTTPHeaderField: "X-Uplift-Variant-Name"))
        if let assignment { onAssignment?(assignment) }
        let headerVersion = parseFlowVersion(response)

        if response.statusCode == 304, let cached {
            // Refresh the cached version if the header carried a newer one.
            let version = headerVersion ?? cached.version
            if let headerVersion, headerVersion != cached.version {
                cache.write(CachedFlow(
                    flowId: flowId, json: cached.json, fetchedAt: Date(),
                    etag: cached.etag, version: version))
            }
            return FetchedFlow(
                json: cached.json, source: .cacheRevalidated, etag: cached.etag,
                flowVersion: version, experimentAssignment: assignment)
        }

        if (200..<300).contains(response.statusCode) {
            guard let body = String(data: data, encoding: .utf8),
                  (try? JSONValue.parse(data)) != nil else {
                if let cached {
                    return FetchedFlow(
                        json: cached.json, source: .cache, etag: cached.etag,
                        flowVersion: cached.version)
                }
                throw FlowFetchError(
                    kind: .invalidPayload, flowKey: flowId,
                    statusCode: response.statusCode)
            }
            let etag = response.value(forHTTPHeaderField: "ETag")
            let entry = CachedFlow(
                flowId: flowId, json: body, fetchedAt: Date(),
                etag: etag, version: headerVersion)
            cache.write(entry)
            return FetchedFlow(
                json: body, source: .network, etag: etag,
                flowVersion: headerVersion, experimentAssignment: assignment)
        }

        // Non-2xx, non-304. If we have a cached copy, fall back silently;
        // otherwise surface a typed, friendly error. Never parse the body.
        if let cached {
            return FetchedFlow(
                json: cached.json, source: .cache, etag: cached.etag,
                flowVersion: cached.version)
        }
        throw FlowFetchError(
            kind: kindForStatus(response.statusCode), flowKey: flowId,
            statusCode: response.statusCode)
    }

    /// Background conditional GET on cache hits. Writes the new body to the
    /// cache on 200, leaves it alone on 304, and never throws.
    private func revalidateInBackground(
        url: URL, flowId: String, apiKey: String?, subjectId: String?,
        bundleId: String?, cached: CachedFlow,
        onAssignment: (@Sendable (UpliftFunnelExperimentAssignment) -> Void)?
    ) async {
        let request = makeRequest(
            url: url, apiKey: apiKey, etag: cached.etag, subjectId: subjectId,
            bundleId: bundleId)
        do {
            let (data, r) = try await session.data(for: request)
            guard let response = r as? HTTPURLResponse else { return }

            let assignment = UpliftFunnelExperimentAssignment.fromHeaders(
                experimentHeader: response.value(forHTTPHeaderField: "X-Uplift-Experiment"),
                variantNameHeader: response.value(forHTTPHeaderField: "X-Uplift-Variant-Name"))
            if let assignment { onAssignment?(assignment) }

            let headerVersion = parseFlowVersion(response)
            if response.statusCode == 304 {
                // Body unchanged, but the version header may have advanced.
                if let headerVersion, headerVersion != cached.version {
                    cache.write(CachedFlow(
                        flowId: flowId, json: cached.json, fetchedAt: Date(),
                        etag: cached.etag, version: headerVersion))
                }
                return
            }
            if (200..<300).contains(response.statusCode) {
                guard let body = String(data: data, encoding: .utf8) else { return }
                let etag = response.value(forHTTPHeaderField: "ETag")
                if body == cached.json && headerVersion == cached.version { return }
                cache.write(CachedFlow(
                    flowId: flowId, json: body, fetchedAt: Date(),
                    etag: etag, version: headerVersion))
            }
        } catch {
            #if DEBUG
            print("[funnel] background revalidation failed for \(flowId): \(error)")
            #endif
        }
    }

    /// Parse the `X-Uplift-Flow-Version` header, or nil if absent/malformed
    /// (e.g. a pre-analytics API that never sends it).
    private func parseFlowVersion(_ response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "X-Uplift-Flow-Version")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func kindForStatus(_ statusCode: Int) -> FlowFetchError.Kind {
        switch statusCode {
        case 404: return .notFound
        case 401: return .unauthorized
        case 403: return .forbidden
        default: return .server
        }
    }
}
