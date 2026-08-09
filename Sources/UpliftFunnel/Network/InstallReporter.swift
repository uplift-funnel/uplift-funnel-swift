import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tells the server what this install is, once, so setup can be checked
/// rather than ticked.
///
/// Two of the things the dashboard's setup gate needs to know never leave the
/// device: whether the host registered a presenter, and whether it set a
/// product catalog. Nothing the server can watch reveals them — the only
/// trigger-side hint (`no_presenter`) is written when a trigger fires, which
/// is long after setup and only once flows exist. So this says so.
///
/// ── Why it coalesces, and why that is the whole design ──────────────────────
///
/// The normal startup sequence is `configure` → `registerPresenter` →
/// `setProducts`, in that order and within a few milliseconds. A report sent
/// from `configure` would therefore say "no presenter, no products" on every
/// correctly-wired app in existence, and the server would draw exactly the
/// wrong conclusion from a perfectly good integration.
///
/// So every call marks the state dirty and the send happens one short delay
/// later, after the host has finished wiring. Three calls at launch produce
/// one request.
///
/// ── Why it is quiet after that ──────────────────────────────────────────────
///
/// The report is a fact about a build, not a heartbeat: it changes when the
/// host changes what it registered, and otherwise not at all. A hash of the
/// last accepted body is kept in `UserDefaults`, and an unchanged body inside
/// the resend interval is not sent. A steady app costs about one request a
/// day; a freshly-wired one reports within seconds of launch.
///
/// Consent governs it. With `trackingEnabled` off nothing is sent, and the
/// server reads the absence as `unknown` rather than as "no presenter" — which
/// is why the server keeps those columns nullable.

/// What the host has told us about itself so far.
struct InstallSnapshot: Sendable, Equatable {
    var sdkVersion: String
    var platform: String
    var osVersion: String?
    var appVersion: String?
    var hasPresenter: Bool
    var productCount: Int
}

/// The snapshot, readable from the reporter's actor and writable from the
/// `@MainActor` facade.
///
/// A box rather than a message. `registerPresenter` and `setProducts` are
/// synchronous facade calls, so pushing a snapshot into the actor means an
/// unstructured `Task` per call — and two of those can be delivered in the
/// order the scheduler feels like, which leaves the reporter holding the older
/// answer and sending it. Reading at send time cannot be out of order: whenever
/// the report goes, it describes the app as it is then.
///
/// Same shape and the same reason as `IdentityBox`.
final class InstallSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: InstallSnapshot

    init(_ value: InstallSnapshot) {
        _value = value
    }

    var value: InstallSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Where the last accepted report's fingerprint lives.
///
/// A two-key wrapper rather than a bare `UserDefaults` on the config: the
/// reporter is an actor, its config crosses an isolation boundary, and
/// `UserDefaults` is not `Sendable`. The rest of the SDK solves this the same
/// way — `UserDefaultsFlowCache`, `UserDefaultsEventQueueStore`.
protocol InstallFingerprintStore: Sendable {
    func read() -> (fingerprint: String, sentAt: TimeInterval)?
    func write(fingerprint: String, sentAt: TimeInterval)
}

final class UserDefaultsInstallFingerprintStore: InstallFingerprintStore, @unchecked Sendable {
    static let fingerprintKey = "funnel.install.fingerprint"
    static let sentAtKey = "funnel.install.sent_at"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func read() -> (fingerprint: String, sentAt: TimeInterval)? {
        guard let fingerprint = defaults.string(forKey: Self.fingerprintKey) else {
            return nil
        }
        return (fingerprint, defaults.double(forKey: Self.sentAtKey))
    }

    func write(fingerprint: String, sentAt: TimeInterval) {
        defaults.set(fingerprint, forKey: Self.fingerprintKey)
        defaults.set(sentAt, forKey: Self.sentAtKey)
    }
}

actor InstallReporter {
    struct Config: Sendable {
        let endpoint: URL
        /// Read at send time, so a key swapped between sessions is picked up.
        let apiKeyProvider: @Sendable () -> String
        let bundleIdProvider: @Sendable () -> String?
        /// The persistent anonymous device id — the same one events carry.
        let installationIdProvider: @Sendable () -> String?
        let urlSession: URLSession
        let store: InstallFingerprintStore
        /// Read at send time. See `InstallSnapshotBox` for why it is a read.
        let snapshot: InstallSnapshotBox

        /// Long enough for the host to finish wiring, short enough that a
        /// developer watching the dashboard sees the row appear.
        var coalesceDelay: TimeInterval = 2
        /// An unchanged report is resent no more often than this.
        var resendInterval: TimeInterval = 24 * 60 * 60
    }

    private let config: Config
    private var trackingEnabled: Bool
    private var pending: Task<Void, Never>?
    private var closed = false

    init(config: Config, trackingEnabled: Bool) {
        self.config = config
        self.trackingEnabled = trackingEnabled
    }

    func setTrackingEnabled(_ enabled: Bool) {
        trackingEnabled = enabled
        if !enabled {
            pending?.cancel()
            pending = nil
        }
    }

    /// Something the report describes has changed. Schedules one send.
    ///
    /// Replacing the pending task rather than adding one is what makes the
    /// launch sequence a single request: each call pushes the send out by the
    /// coalescing delay, so the report describes the app *after* wiring rather
    /// than during it.
    func noteChanged() {
        schedule()
    }

    private func schedule() {
        guard !closed, trackingEnabled else { return }
        pending?.cancel()
        let delay = config.coalesceDelay
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.send()
        }
    }

    /// Send now, skipping the delay. The test seam, and nothing else calls it.
    func flush() async {
        pending?.cancel()
        pending = nil
        await send()
    }

    func close() {
        closed = true
        pending?.cancel()
        pending = nil
    }

    // MARK: - Sending

    private func send() async {
        pending = nil
        guard trackingEnabled else { return }

        let apiKey = config.apiKeyProvider()
        guard !apiKey.isEmpty else { return }
        guard let installationId = config.installationIdProvider(),
              !installationId.isEmpty else { return }

        let snapshot = config.snapshot.value
        let fingerprint = Self.fingerprint(snapshot, installationId: installationId)
        if !shouldSend(fingerprint: fingerprint) { return }
        let body = payload(snapshot, installationId: installationId)

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // The server rations this per device, not per key — a public key is
        // shared by every install of the app.
        request.setValue(installationId, forHTTPHeaderField: "X-Uplift-Subject-Id")
        if let bundleId = config.bundleIdProvider(), !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Uplift-Bundle-Id")
        }
        request.httpBody = try? body.serializedData()

        guard let (_, response) = try? await config.urlSession.data(for: request) else {
            // Unreachable server. Nothing is recorded, so the next launch
            // tries again — this report is not worth a retry timer.
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return }

        // Only a report the server actually took suppresses the next one.
        config.store.write(fingerprint: fingerprint, sentAt: Date().timeIntervalSince1970)
    }

    /// What "the same report" means, in a fixed order.
    ///
    /// Built from the fields rather than from the serialized body, and the
    /// difference is not stylistic: `JSONEncoder` writes a dictionary in its
    /// iteration order, and two dictionaries with identical contents do not
    /// iterate the same way — measured, in one process, twice in a row. A
    /// fingerprint taken from those bytes is effectively random, which would
    /// have made every launch look like a change and resent the report
    /// forever.
    static func fingerprint(_ s: InstallSnapshot, installationId: String) -> String {
        [
            installationId,
            s.sdkVersion,
            s.platform,
            s.osVersion ?? "",
            s.appVersion ?? "",
            s.hasPresenter ? "1" : "0",
            String(s.productCount),
        ].joined(separator: "\u{1F}")
    }

    private func payload(_ snapshot: InstallSnapshot, installationId: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "installation_id": .string(installationId),
            "sdk_version": .string(snapshot.sdkVersion),
            "platform": .string(snapshot.platform),
            "has_presenter": .bool(snapshot.hasPresenter),
            "product_count": .number(Double(snapshot.productCount)),
        ]
        if let os = snapshot.osVersion, !os.isEmpty {
            object["os_version"] = .string(os)
        }
        if let appVersion = snapshot.appVersion, !appVersion.isEmpty {
            object["app_version"] = .string(appVersion)
        }
        return .object(object)
    }

    /// Changed, or old enough to be worth repeating.
    private func shouldSend(fingerprint: String) -> Bool {
        guard let last = config.store.read() else { return true }
        if last.fingerprint != fingerprint { return true }
        if last.sentAt <= 0 { return true }
        return Date().timeIntervalSince1970 - last.sentAt >= config.resendInterval
    }
}
