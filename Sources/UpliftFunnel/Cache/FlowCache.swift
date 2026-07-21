import Foundation

// UserDefaults-backed cache for flow JSON, ported from the Flutter SDK's
// `cache/flow_cache.dart`. Stores raw JSON + ETag + fetch timestamp keyed by
// flow id, so the SDK can serve onboarding even on cold start with no
// network, and revalidate cheaply via If-None-Match.

public struct CachedFlow: Sendable, Equatable {
    public let flowId: String
    public let json: String
    public let fetchedAt: Date
    public let etag: String?

    /// Published flow version (from the `X-Uplift-Flow-Version` header).
    /// Cached alongside the JSON so a warm-cache start can still stamp it on
    /// events.
    public let version: Int?

    public init(
        flowId: String, json: String, fetchedAt: Date,
        etag: String? = nil, version: Int? = nil
    ) {
        self.flowId = flowId
        self.json = json
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.version = version
    }

    func toJSONString() -> String {
        var obj: [String: JSONValue] = [
            "flow_id": .string(flowId),
            "json": .string(json),
            "fetched_at": .number(Double(Int64(fetchedAt.timeIntervalSince1970 * 1000))),
        ]
        if let etag { obj["etag"] = .string(etag) }
        if let version { obj["version"] = .number(Double(version)) }
        return JSONValue.object(obj).serializedString()
    }

    static func fromJSONStringOrNil(_ raw: String) -> CachedFlow? {
        guard let m = try? JSONValue.parse(raw),
              let flowId = m["flow_id"].stringValue,
              let json = m["json"].stringValue,
              let fetchedAtMs = m["fetched_at"].doubleValue else {
            return nil
        }
        return CachedFlow(
            flowId: flowId,
            json: json,
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            etag: m["etag"].stringValue,
            // Backward-compatible: entries written before analytics V1 have
            // no version.
            version: m["version"].intValue)
    }
}

public protocol FlowCache: Sendable {
    func read(flowId: String) -> CachedFlow?
    func write(_ entry: CachedFlow)
    func evict(flowId: String)
    func clear()
}

/// Default persistent cache. Key names intentionally match the Flutter SDK
/// (`funnel.flow.<flowId>`) for cross-SDK conceptual parity.
public final class UserDefaultsFlowCache: FlowCache, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "funnel.flow.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(_ flowId: String) -> String { keyPrefix + flowId }

    public func read(flowId: String) -> CachedFlow? {
        guard let raw = defaults.string(forKey: key(flowId)) else { return nil }
        return CachedFlow.fromJSONStringOrNil(raw)
    }

    public func write(_ entry: CachedFlow) {
        defaults.set(entry.toJSONString(), forKey: key(entry.flowId))
    }

    public func evict(flowId: String) {
        defaults.removeObject(forKey: key(flowId))
    }

    public func clear() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: k)
        }
    }
}

public final class InMemoryFlowCache: FlowCache, @unchecked Sendable {
    private var store: [String: CachedFlow] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(flowId: String) -> CachedFlow? {
        lock.lock(); defer { lock.unlock() }
        return store[flowId]
    }

    public func write(_ entry: CachedFlow) {
        lock.lock(); defer { lock.unlock() }
        store[entry.flowId] = entry
    }

    public func evict(flowId: String) {
        lock.lock(); defer { lock.unlock() }
        store[flowId] = nil
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}
