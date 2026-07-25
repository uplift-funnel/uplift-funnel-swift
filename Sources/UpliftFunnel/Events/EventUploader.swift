import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Buffered HTTP event uploader, ported from the Flutter SDK's
// `events/event_uploader.dart`. Maps FlowEvents to the funnel-api wire shape
// and POSTs in small batches (every N events or M seconds). Failed posts are
// retried with exponential backoff up to a small cap; if the buffer
// overflows on a long offline stretch, the oldest events are dropped — the
// analytics surface tolerates loss better than the SDK ballooning memory.

struct EventUploaderConfig: Sendable {
    let endpoint: URL

    var flushEvery: TimeInterval = 5
    var flushAt: Int = 20
    var maxBuffer: Int = 500

    /// Byte ceiling for the persisted buffer; oldest events are dropped
    /// first.
    var maxBufferBytes: Int = 256 * 1024

    /// Exponential-backoff base and cap for retrying failed uploads
    /// (delay = min(base * 2^(n-1), max) + jitter).
    var retryBackoffBase: TimeInterval = 5
    var retryBackoffMax: TimeInterval = 300

    /// Returns the Bearer token to authenticate event uploads. Read at
    /// flush time so callers can swap the active key between sessions.
    /// Returning an empty string suppresses the upload — the batch is
    /// dropped client-side rather than triggering 401 spam.
    let apiKeyProvider: @Sendable () -> String

    /// Returns the host app's bundle id, or nil when unknown. Read at flush
    /// time and sent as `X-Uplift-Bundle-Id` so the server can pin the API
    /// key to the app it belongs to.
    var bundleIdProvider: (@Sendable () -> String?)?

    /// Read at serialize time so `identify` calls after the uploader was
    /// constructed are picked up on subsequent events.
    var userIdProvider: (@Sendable () -> String?)?

    /// Read at serialize time so every event carries the persistent
    /// anonymous device id (the server also uses it for identity merge).
    var anonymousIdProvider: (@Sendable () -> String?)?

    /// Returns the ambient event context (platform/os/app/sdk/locale/
    /// attribution). Read at serialize time so `setAttribution` updates
    /// take effect on subsequent events.
    var contextProvider: (@Sendable () -> [String: JSONValue])?

    /// Optional durable store for the pending-event buffer. When set, the
    /// buffer is persisted (debounced) and restored via `restore()` so
    /// events survive an app kill.
    var queueStore: EventQueueStore?

    var urlSession: URLSession = .shared
}

actor EventUploader {
    nonisolated let config: EventUploaderConfig

    private var buffer: [[String: JSONValue]] = []
    private var flushTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var flushing = false
    private var consecutiveFailures = 0
    private var warnedNoKey = false
    private var closed = false

    init(config: EventUploaderConfig) {
        self.config = config
    }

    /// Restore any events persisted from a previous app run and schedule a
    /// flush. Call once after construction.
    func restore() {
        guard let store = config.queueStore else { return }
        let restored = store.load()
        guard !restored.isEmpty else { return }
        buffer.insert(contentsOf: restored, at: 0)
        enforceCaps()
        scheduleFlush(after: config.flushEvery)
    }

    // MARK: - Serialization (pure; called from the session's listener)

    /// Client-generated dedup id. Generated at serialize (enqueue) time and
    /// baked into the buffered event, so a re-queued batch reuses the same
    /// id and the server dedups the retry.
    private nonisolated func newEventId() -> String { Identifiers.eventId() }

    private nonisolated func identityFields() -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let uid = config.userIdProvider?() { fields["user_id"] = .string(uid) }
        if let anon = config.anonymousIdProvider?() { fields["anonymous_id"] = .string(anon) }
        if let ctx = config.contextProvider?(), !ctx.isEmpty {
            fields["context"] = .object(ctx)
        }
        return fields
    }

    /// Maps a FlowEvent to the `/v1/events` wire shape.
    nonisolated func serialize(
        _ e: FlowEvent,
        sessionId: String,
        flowId: String,
        experiment: UpliftFunnelExperimentAssignment?,
        flowVersion: Int?
    ) -> [String: JSONValue] {
        var base = identityFields()
        base["event_id"] = .string(newEventId())
        base["session_id"] = .string(sessionId)
        base["flow_id"] = .string(flowId)
        if let flowVersion { base["flow_version"] = .number(Double(flowVersion)) }
        // Experiment attribution — present only for sessions started via
        // startExperiment. The API accepts (and older APIs ignore) these
        // optional fields, so untagged sessions stay wire-compatible.
        if let experiment {
            base["experiment_id"] = .string(experiment.experimentId)
            base["variant_id"] = .string(experiment.variantId)
        }

        func stamp(_ date: Date) {
            base["timestamp"] = .number(Double(Int64(date.timeIntervalSince1970 * 1000)))
        }

        switch e {
        case .started(_, let ts, let entryScreenId):
            stamp(ts)
            base["event_type"] = "flow_started"
            base["screen_id"] = .string(entryScreenId)
        case .screenChanged(_, let ts, let from, let to):
            stamp(ts)
            base["event_type"] = "screen_changed"
            base["screen_id"] = .string(to)
            base["payload"] = .object(["from": .string(from)])
        case .variableSet(_, let ts, let screenId, let name, let value):
            stamp(ts)
            base["event_type"] = "variable_set"
            base["screen_id"] = .string(screenId)
            base["payload"] = .object(["name": .string(name), "value": value])
        case .custom(_, let ts, let name, _):
            stamp(ts)
            base["event_type"] = "custom_event"
            base["payload"] = .object(["name": .string(name)])
        // First-class event types (purchase_attempted, ...) rather than
        // payload-wrapped custom_events, so server-side funnel queries hit
        // the (app_id, flow_id, event_type) index directly.
        case .purchase(_, let ts, let stage, let screenId, let planId, let productId):
            stamp(ts)
            base["event_type"] = .string("purchase_\(stage)")
            base["screen_id"] = .string(screenId)
            var payload: [String: JSONValue] = [:]
            if let planId { payload["plan_id"] = .string(planId) }
            if let productId { payload["product_id"] = .string(productId) }
            base["payload"] = .object(payload)
        case .completed(_, let ts, let reason, let variables):
            stamp(ts)
            base["event_type"] = (reason == "completed" || reason == "completed:end")
                ? "flow_completed" : "flow_abandoned"
            base["payload"] = .object([
                "reason": .string(reason),
                "variables": .object(variables),
            ])
        }
        return base
    }

    // MARK: - Enqueue

    func enqueue(_ event: [String: JSONValue]) {
        buffer.append(event)
        enforceCaps()
        persistDebounced()
        scheduleFlush(after: config.flushEvery)
        if buffer.count >= config.flushAt {
            Task { await self.flush() }
        }
    }

    /// Enqueue a custom app-level event (`UpliftFunnel.track`). `flowId` is
    /// omitted for events fired outside a flow session — the server stamps
    /// its "_app" sentinel. Carries the same identity/context fields as
    /// flow events.
    func enqueueCustom(
        name: String,
        sessionId: String,
        flowId: String? = nil,
        properties: [String: JSONValue]? = nil,
        experiment: UpliftFunnelExperimentAssignment? = nil
    ) {
        var event = identityFields()
        event["event_id"] = .string(newEventId())
        event["session_id"] = .string(sessionId)
        if let flowId { event["flow_id"] = .string(flowId) }
        event["event_type"] = .string(name)
        event["timestamp"] = .number(Double(Int64(Date().timeIntervalSince1970 * 1000)))
        if let experiment {
            event["experiment_id"] = .string(experiment.experimentId)
            event["variant_id"] = .string(experiment.variantId)
        }
        if let properties { event["payload"] = .object(properties) }
        enqueue(event)
    }

    // MARK: - Caps / persistence

    /// Enforce the count cap (drop-oldest) and, when a store is configured,
    /// the byte cap. The byte trim re-encodes only when over budget, so the
    /// common path stays cheap.
    private func enforceCaps() {
        if buffer.count > config.maxBuffer {
            buffer.removeFirst(buffer.count - config.maxBuffer)
        }
        if config.queueStore != nil {
            var encoded = encodedByteCount()
            while encoded > config.maxBufferBytes && buffer.count > 1 {
                buffer.removeFirst()
                encoded = encodedByteCount()
            }
        }
    }

    private func encodedByteCount() -> Int {
        (try? JSONValue.array(buffer.map { .object($0) }).serializedData().count) ?? 0
    }

    private func persistDebounced() {
        guard config.queueStore != nil else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        guard let store = config.queueStore else { return }
        persistTask?.cancel()
        persistTask = nil
        if buffer.isEmpty {
            store.clear()
        } else {
            enforceCaps()
            store.save(buffer)
        }
    }

    // MARK: - Flush

    private func scheduleFlush(after delay: TimeInterval) {
        guard flushTask == nil, !closed else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Clear the handle BEFORE flushing — flush() cancels any pending
            // flushTask, and cancelling ourselves here would abort the
            // in-flight URLSession request.
            await self?.scheduledFlushFired()
        }
    }

    private func scheduledFlushFired() async {
        flushTask = nil
        await flush()
    }

    private func backoffDelay(failures: Int) -> TimeInterval {
        let base = config.retryBackoffBase
        let cap = config.retryBackoffMax
        let shift = min(max(failures - 1, 0), 20)
        let exp = min(max(base * TimeInterval(1 << shift), base), cap)
        let jitter = Double.random(in: 0..<1) * 0.25 * exp
        return exp + jitter
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        if flushing || buffer.isEmpty { return }
        flushing = true
        let batch = buffer
        buffer.removeAll()

        let apiKey = config.apiKeyProvider()
        if apiKey.isEmpty {
            // No active key — drop and surface a one-time hint. Avoids
            // spamming 401s when the host hasn't wired the SDK key yet.
            #if DEBUG
            if !warnedNoKey {
                warnedNoKey = true
                print("[funnel] events: no apiKey configured — dropping "
                      + "\(batch.count) events. Call UpliftFunnel.configure"
                      + "(apiKey:) at startup.")
            }
            #endif
            flushing = false
            persist()
            return
        }

        var failed = false
        do {
            var request = URLRequest(url: config.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let bundleId = config.bundleIdProvider?(), !bundleId.isEmpty {
                request.setValue(bundleId, forHTTPHeaderField: "X-Uplift-Bundle-Id")
            }
            request.httpBody = try JSONValue.object(
                ["events": .array(batch.map { .object($0) })]
            ).serializedData()

            let (_, response) = try await config.urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                if (400..<500).contains(status) {
                    // On 4xx the events are likely malformed or auth is
                    // wrong and would never succeed — drop them rather than
                    // infinite-retry.
                    #if DEBUG
                    print("[funnel] events: server rejected batch \(status), "
                          + "dropping \(batch.count) events")
                    #endif
                } else {
                    // 5xx → re-queue to the front for retry with backoff.
                    buffer.insert(contentsOf: batch, at: 0)
                    failed = true
                }
            }
        } catch {
            // Transport error — re-queue.
            buffer.insert(contentsOf: batch, at: 0)
            failed = true
            #if DEBUG
            print("[funnel] events: post failed: \(error)")
            #endif
        }

        flushing = false
        if failed {
            consecutiveFailures += 1
            enforceCaps()
            persist()
            // Exponential backoff on repeated failures instead of a fixed
            // cadence.
            scheduleFlush(after: backoffDelay(failures: consecutiveFailures))
        } else {
            consecutiveFailures = 0
            persist()
            // Schedule another flush if more events arrived during this one.
            if !buffer.isEmpty {
                scheduleFlush(after: config.flushEvery)
            }
        }
    }

    /// Flush + persist without tearing down the uploader. Called on app
    /// background so events reach the server (or disk) before the OS
    /// suspends the process.
    func flushNow() async {
        await flush()
        persist()
    }

    /// Force a final drain (app background or session teardown).
    func close() async {
        closed = true
        persistTask?.cancel()
        persistTask = nil
        flushTask?.cancel()
        flushTask = nil
        await flush()
        persist()
    }

    // Test hooks.
    var bufferedEventCount: Int { buffer.count }
    var bufferedEvents: [[String: JSONValue]] { buffer }
}
