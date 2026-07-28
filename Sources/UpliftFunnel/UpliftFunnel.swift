import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Top-level Uplift Funnel SDK facade, ported from the Flutter SDK's
// `uplift_funnel.dart`. Static methods only — host code never sees the
// singleton, the URL composition, the cache, or the event uploader.
//
//   // 1) at app startup
//   await UpliftFunnel.configure(apiKey: "fnl_pk_xyz")
//
//   // 2) start an onboarding by its key
//   let start = try await UpliftFunnel.start("cal-ai-clone")

/// Host-side auth handoff for `signin` nodes. Receives the tapped provider
/// id (`apple`, `google`, `facebook`, `email`, `anonymous`), runs the app's
/// real sign-in flow and resolves to `true` on success.
public typealias SignInHandler = @MainActor (String) async -> Bool

/// Host-side OS-permission handoff for `permission` nodes. Receives the
/// permission key (`notifications`, `camera`, `tracking`, …), shows the real
/// system dialog and resolves to the grant result. Without a handler the SDK
/// mocks an immediate grant — useful in previews and demos.
public typealias PermissionHandler = @MainActor (String) async -> Bool

/// Host-side restore-purchases handoff for the `restore` button action.
/// Resolve `true` only when something was actually restored — that's what
/// lets the flow advance.
public typealias RestoreHandler = @MainActor () async -> Bool

/// Host-side opener for `url:<href>` actions — markdown links and buttons
/// with a `url:` action. Typically `{ UIApplication.shared.open(URL(...)!) }`.
/// Without a handler link taps are no-ops.
public typealias LinkHandler = @MainActor (String) -> Void

/// Typed SDK errors thrown by the facade.
public enum UpliftFunnelError: Error, LocalizedError {
    /// A method was called before `UpliftFunnel.configure`.
    case notConfigured(method: String)
    /// `track` was called with a name not matching `^[a-z][a-z0-9_:]*$`.
    case invalidEventName(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let method):
            return "UpliftFunnel has not been configured. Call "
                + "UpliftFunnel.configure(apiKey:) at app startup before "
                + "using any other API. Called: \(method)."
        case .invalidEventName(let name):
            return "custom event name must match ^[a-z][a-z0-9_:]*$ (got \"\(name)\")"
        }
    }
}

/// Result of `UpliftFunnel.start` / `UpliftFunnel.startExperiment`. Carries
/// the session host code renders + a label describing whether the flow JSON
/// came from network, cache, or a 304 revalidation.
public struct FlowSessionStart {
    public let session: FlowSession
    public let source: FetchSource

    /// Published version of the flow JSON that was rendered, or nil for an
    /// experiment session / a pre-analytics API.
    public let flowVersion: Int?

    /// The A/B assignment this session was started under, or nil when the
    /// flow wasn't started via `startExperiment` or no running experiment
    /// matched. On a warm-cache start the value comes from the persisted
    /// assignment for the experiment key; background revalidation refreshes
    /// it.
    public let experiment: UpliftFunnelExperimentAssignment?
}

/// Top-level Uplift Funnel SDK facade. Caseless enum — statics only.
@MainActor
public enum UpliftFunnel {
    static var state: FunnelState?

    /// True if `configure` has run successfully at least once.
    public static var isConfigured: Bool { state != nil }

    /// Initialise the SDK. Call once at app startup.
    ///
    /// - `apiKey` — your public Uplift Funnel API key (`fnl_pk_…`). Sent as
    ///   a Bearer token on every fetch and event upload. The server resolves
    ///   which app the key belongs to.
    /// - `serverUrl` — optional override for local dev / staging. Defaults
    ///   to `https://api.upliftfunnel.com`. Must be an absolute http(s) URL;
    ///   cleartext `http://` is accepted in debug builds only, so a release
    ///   build can't ship the API key and the event stream in the clear.
    /// - `bundleId` — your app's bundle id, sent as `X-Uplift-Bundle-Id` on
    ///   every request so the server can pin your API key to this app — a
    ///   leaked key becomes useless anywhere else. Defaults to
    ///   `Bundle.main.bundleIdentifier`; pass it explicitly only to override.
    ///
    /// Idempotent: calling `configure` again replaces the previous
    /// configuration but keeps the stable per-install anonymous id, so
    /// sticky A/B variants stay sticky across config swaps.
    public static func configure(
        apiKey: String,
        serverUrl: String? = nil,
        appVersion: String? = nil,
        bundleId: String? = nil
    ) async {
        await configureInternal(
            apiKey: apiKey, serverUrl: serverUrl, appVersion: appVersion,
            bundleId: bundleId)
    }

    /// Test seam: also injects the URLSession and the UserDefaults suite.
    static func configureInternal(
        apiKey: String,
        serverUrl: String? = nil,
        appVersion: String? = nil,
        bundleId: String? = nil,
        urlSession: URLSession? = nil,
        defaults: UserDefaults = .standard
    ) async {
        // Validate before touching existing state: a bad serverUrl must not
        // leave a previously-configured SDK half torn down. A malformed or
        // cleartext-in-release URL is a wiring mistake, not a runtime
        // condition, so it fails loudly rather than silently falling back to
        // production (which would ship staging traffic to the live API).
        let resolvedServerUrl: String
        if let serverUrl {
            #if DEBUG
            let allowCleartext = true
            #else
            let allowCleartext = false
            #endif
            do {
                resolvedServerUrl = try normalizeServerUrl(
                    serverUrl, allowCleartext: allowCleartext)
            } catch {
                preconditionFailure("UpliftFunnel.configure: \(error)")
            }
        } else {
            resolvedServerUrl = FunnelState.defaultServerUrl
        }

        let previous = state

        // Tear down a previous uploader so its timers don't leak.
        if let uploader = previous?.uploader {
            await uploader.close()
        }
        previous?.removeLifecycleObserver()

        let session = urlSession ?? FlowFetcher.makeSession()
        let cache = UserDefaultsFlowCache(defaults: defaults)
        let fetcher = FlowFetcher(cache: cache, urlSession: session)
        let s = FunnelState(
            apiKey: apiKey,
            serverUrl: resolvedServerUrl,
            cache: cache,
            fetcher: fetcher,
            urlSession: session,
            defaults: defaults)

        // Carry state that must survive a config swap.
        if let previous {
            s.identity.anonymousId = previous.identity.anonymousId
            s.identity.userId = previous.identity.userId
            s.userAttributes = previous.userAttributes
            s.attribution = previous.attribution
            s.signInHandler = previous.signInHandler
            s.permissionHandler = previous.permissionHandler
            s.purchaseHandler = previous.purchaseHandler
            s.restoreHandler = previous.restoreHandler
            s.photoUploadHandler = previous.photoUploadHandler
            s.linkHandler = previous.linkHandler
            s.allowedLinkSchemes = previous.allowedLinkSchemes
            s.products = previous.products
        }
        s.appVersion = appVersion
        // Auto-detect the host bundle id (unlike Flutter, iOS can) so the
        // server-side key pinning works without any host wiring.
        s.bundleId = bundleId ?? Bundle.main.bundleIdentifier
        s.identity.activeApiKey = apiKey.isEmpty ? nil : apiKey

        // Restore persisted identity/attribution and ensure the anonymous
        // id exists unconditionally, so every event carries it. Then
        // snapshot the event context.
        s.loadPersistedIdentity()
        s.rebuildEventContext()

        s.uploader = s.makeUploader()
        // Restore any events persisted from a previous run.
        await s.uploader?.restore()
        s.registerLifecycleObserver()
        state = s
    }

    /// Bind a known user. Sticky A/B variants follow them across devices —
    /// fetches use `userId` as the subject id when present, falling back to
    /// the per-install anonymous id otherwise.
    ///
    /// Persists `userId` so identity survives restarts, and best-effort
    /// POSTs the anonymous→user mapping to `/v1/identify`. `attributes` are
    /// injected as `user.<key>` flow-condition variables; they are not sent
    /// to the analytics API in V1.
    public static func identify(
        userId: String, attributes: [String: JSONValue]? = nil
    ) async throws {
        let s = try require("identify")
        s.identity.userId = userId
        s.userAttributes = attributes ?? [:]
        s.rebuildEventContext()
        s.defaults.set(userId, forKey: FunnelState.identifiedUserIdKey)
        if let anon = s.ensureAnonymousId() {
            s.postIdentify(userId: userId, anonymousId: anon)
        }
    }

    /// Clear the identified user (logout). Generates a fresh anonymous id
    /// so the next person on the device is tracked as a new subject and A/B
    /// stickiness resets. Attributes and attribution are cleared too.
    public static func resetIdentity() async throws {
        let s = try require("resetIdentity")
        s.identity.userId = nil
        s.userAttributes = [:]
        let fresh = Identifiers.anonymousId()
        s.identity.anonymousId = fresh
        s.defaults.removeObject(forKey: FunnelState.identifiedUserIdKey)
        s.defaults.set(fresh, forKey: FunnelState.anonymousIdKey)
        s.rebuildEventContext()
    }

    /// Set acquisition attribution (source/campaign/ad_set/creative).
    /// Persisted and merged into the context on every subsequent event.
    /// Unknown keys are ignored and values are truncated to keep PII /
    /// free-form data out.
    public static func setAttribution(_ attribution: [String: String]) async throws {
        let s = try require("setAttribution")
        var filtered: [String: String] = [:]
        for (k, v) in attribution
        where FunnelState.attributionKeys.contains(k) && !v.isEmpty {
            filtered[k] = String(v.prefix(FunnelState.maxAttributionValueLen))
        }
        s.attribution = filtered
        s.rebuildEventContext()
        let json = JSONValue.object(filtered.mapValues { .string($0) })
        s.defaults.set(json.serializedString(), forKey: FunnelState.attributionKey)
    }

    /// Record a custom conversion event (e.g. `first_workout_completed`)
    /// from anywhere in the app — not just inside a flow. Events are queued
    /// durably and uploaded in batches with retry.
    ///
    /// `name` must match `^[a-z][a-z0-9_:]*$`; an invalid name throws
    /// locally (it never poisons a batch). When a flow session is active
    /// its flow/session/experiment context is attached; otherwise a
    /// per-launch app-session id is used and the server records it against
    /// its "_app" sentinel flow.
    public static func track(
        _ name: String, properties: [String: JSONValue]? = nil
    ) async throws {
        let s = try require("track")
        guard FunnelState.eventNameRegex.firstMatch(
            in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
            throw UpliftFunnelError.invalidEventName(name)
        }
        let session = s.lastBoundSession
        let sessionId = session?.sessionId ?? s.ensureAppSessionId()
        let flowId = session?.flow.id
        let experiment = session?.experiment
        guard let uploader = s.uploader else { return }
        await uploader.enqueueCustom(
            name: name, sessionId: sessionId, flowId: flowId,
            properties: properties, experiment: experiment)
    }

    /// Fetch + start an onboarding by its `key`. Cache-first with
    /// background revalidation: a hot cache returns instantly and the SDK
    /// fires a conditional GET in the background to refresh next launch's
    /// copy.
    ///
    /// Pass `forceRefresh: true` to bypass the cache (e.g. dashboard
    /// preview). `userVariables` are merged into the engine's variable
    /// scope before the first transition is evaluated.
    public static func start(
        _ key: String,
        forceRefresh: Bool = false,
        userVariables: [String: JSONValue]? = nil
    ) async throws -> FlowSessionStart {
        let s = try require("start")
        guard let url = apiURL(serverUrl: s.serverUrl, path: "v1/flows", key: key)
        else {
            throw FlowFetchError(
                kind: .notFound, flowKey: key,
                message: "not a usable flow key")
        }
        let fetched = try await s.fetcher.fetch(
            url: url, flowId: key, apiKey: s.apiKey, bundleId: s.bundleId,
            forceRefresh: forceRefresh)
        s.lastExperimentAssignment = nil
        let session = try s.session(
            fromJson: fetched.json,
            userVariables: userVariables,
            flowVersion: fetched.flowVersion)
        return FlowSessionStart(
            session: session, source: fetched.source,
            flowVersion: fetched.flowVersion, experiment: nil)
    }

    /// Fetch + start an A/B-routed flow by its experiment `key`. The SDK
    /// attaches the sticky subject id (the identified user id, or the
    /// per-install anonymous id) so the API buckets the user into a stable
    /// variant.
    ///
    /// On rolled-out / stopped experiments the API serves the chosen or
    /// baseline variant respectively, so leaving this call in production
    /// after a decision is safe.
    public static func startExperiment(
        _ key: String,
        forceRefresh: Bool = false,
        userVariables: [String: JSONValue]? = nil
    ) async throws -> FlowSessionStart {
        let s = try require("startExperiment")
        let subjectId = s.identity.userId ?? s.ensureAnonymousId()
        guard let url = apiURL(
            serverUrl: s.serverUrl, path: "v1/experiments", key: key)
        else {
            throw FlowFetchError(
                kind: .notFound, flowKey: key,
                message: "not a usable experiment key")
        }
        let fetched = try await s.fetcher.fetch(
            url: url, flowId: key, apiKey: s.apiKey, subjectId: subjectId,
            bundleId: s.bundleId,
            forceRefresh: forceRefresh,
            // Background revalidation (and the foreground response) report
            // the server's current assignment here; persist it so the next
            // warm-cache start surfaces the up-to-date variant.
            onAssignment: { [weak s] assignment in
                Task { @MainActor in
                    guard let s else { return }
                    s.lastExperimentAssignment = assignment
                    s.persistAssignment(key, assignment)
                }
            })

        // Resolve the effective assignment for this start:
        //   - Network / 304: the header-derived assignment.
        //   - Warm cache hit: the header wasn't seen, so fall back to the
        //     last persisted assignment for this experiment key. Sticky
        //     bucketing makes this correct.
        let assignment: UpliftFunnelExperimentAssignment?
        if fetched.source == .cache {
            assignment = s.readPersistedAssignment(key)
        } else {
            assignment = fetched.experimentAssignment
            // A nil on a matched fetch means the experiment stopped /
            // rolled out for this subject — leave the last known value
            // untouched rather than forgetting stickiness.
            if let assignment { s.persistAssignment(key, assignment) }
        }

        s.lastExperimentAssignment = assignment
        let session = try s.session(
            fromJson: fetched.json,
            userVariables: userVariables,
            experiment: assignment)
        return FlowSessionStart(
            session: session, source: fetched.source,
            flowVersion: nil, experiment: assignment)
    }

    // MARK: - Handler registration

    /// Register the app's auth handoff for `signin` nodes. On `true` the
    /// provider is saved to the node's bound variable and the flow
    /// advances. Without a handler, taps succeed immediately.
    public static func registerSignInHandler(_ handler: @escaping SignInHandler) {
        requireForRegistration("registerSignInHandler")?.signInHandler = handler
    }

    /// Register the app's OS-permission handoff for `permission` nodes.
    /// Without a handler, taps record an immediate grant (preview/demo
    /// behavior).
    public static func registerPermissionHandler(_ handler: @escaping PermissionHandler) {
        requireForRegistration("registerPermissionHandler")?.permissionHandler = handler
    }

    /// Register the app's billing handoff for the `purchase` button action.
    /// Only `.purchased` lets the flow advance. Every attempt and its
    /// outcome is auto-tracked so paywall drop-off shows up in analytics.
    /// Without a handler `purchase` simply advances — paywalls stay inert
    /// until billing is wired.
    ///
    /// `productPrices` is a convenience for price display only. Prefer
    /// `setProducts` — it also unlocks per-period/trial variables and
    /// plan-card auto-binding data.
    public static func registerPurchaseHandler(
        _ handler: @escaping PurchaseHandler,
        productPrices: [String: String]? = nil
    ) {
        guard let s = requireForRegistration("registerPurchaseHandler") else { return }
        s.purchaseHandler = handler
        if let productPrices {
            setProducts(productPrices.map { UpliftFunnelProduct(id: $0.key, price: $0.value) })
        }
    }

    /// Set the runtime product catalog used for paywall display. Each
    /// product fans out into `<field>.<productId>` variables at the start
    /// of every session — `price.X`, `price_per_month.X`, `trial_days.X`,
    /// … — so flow text interpolates `{{price.X}}` and `plan_picker` cards
    /// auto-bind their price display via the plan's `product_id`.
    ///
    /// Call after fetching offerings from your billing stack; safe to call
    /// again on refresh. Replaces the whole catalog.
    public static func setProducts(_ products: [UpliftFunnelProduct]) {
        guard let s = requireForRegistration("setProducts") else { return }
        s.products = Dictionary(
            products.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Register the app's restore-purchases handoff for the `restore`
    /// button action. Return `true` only when something was actually
    /// restored. Without a handler, or a `false` result, `restore` no-ops
    /// instead of advancing.
    public static func registerRestoreHandler(_ handler: @escaping RestoreHandler) {
        requireForRegistration("registerRestoreHandler")?.restoreHandler = handler
    }

    /// Register the app's photo picker for the `photo_upload` primitive.
    public static func registerPhotoUploadHandler(_ handler: @escaping PhotoUploadHandler) {
        requireForRegistration("registerPhotoUploadHandler")?.photoUploadHandler = handler
    }

    /// Register the app's URL opener for `url:<href>` actions — markdown
    /// links in text nodes and buttons with a `url:` action.
    ///
    /// The href is authored content that arrives over the network, so the SDK
    /// only forwards URLs whose scheme is in `allowedSchemes` — by default
    /// ``defaultAllowedLinkSchemes`` (`https`, `http`, `mailto`, `tel`,
    /// `sms`). Anything else is dropped before the handler runs, so a flow
    /// can't make the app follow a custom app scheme, a `file://` path, or one
    /// of the app's own deep links.
    ///
    /// Pass `allowedSchemes` to opt specific schemes in — e.g. an app that
    /// deliberately drives its own routes from a flow:
    ///
    /// ```swift
    /// UpliftFunnel.registerLinkHandler(
    ///     open, allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes.union(["myapp"]))
    /// ```
    public static func registerLinkHandler(
        _ handler: @escaping LinkHandler,
        allowedSchemes: Set<String> = UpliftFunnel.defaultAllowedLinkSchemes
    ) {
        guard let s = requireForRegistration("registerLinkHandler") else { return }
        s.linkHandler = handler
        s.allowedLinkSchemes = Set(allowedSchemes.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
    }

    /// Hand `url` to the registered link opener, but only when its scheme is
    /// allowed (see ``registerLinkHandler(_:allowedSchemes:)``). Returns
    /// whether the handler actually ran.
    ///
    /// The scheme check lives here rather than at the call site so no future
    /// `url:` path can reach the host opener without passing it.
    @discardableResult
    static func openLink(_ url: String) -> Bool {
        guard let s = state, let handler = s.linkHandler else { return false }
        guard isAllowedLinkURL(url, allowedSchemes: s.allowedLinkSchemes) else {
            #if DEBUG
            print("[funnel] blocked a url: action with a disallowed scheme: "
                  + "\(url) — allow it via registerLinkHandler(_:allowedSchemes:).")
            #endif
            return false
        }
        handler(url)
        return true
    }

    // MARK: - Render-layer lookups (internal)

    static func lookupSignInHandler() -> SignInHandler? { state?.signInHandler }
    static func lookupPermissionHandler() -> PermissionHandler? { state?.permissionHandler }
    static func lookupPurchaseHandler() -> PurchaseHandler? { state?.purchaseHandler }
    static func lookupRestoreHandler() -> RestoreHandler? { state?.restoreHandler }
    static func lookupPhotoUploadHandler() -> PhotoUploadHandler? { state?.photoUploadHandler }
    static func lookupProducts() -> [String: UpliftFunnelProduct] { state?.products ?? [:] }

    /// Drain the in-memory event uploader buffer. Usually unnecessary — the
    /// uploader auto-flushes on its own cadence and on app background.
    public static func flushEvents() async {
        guard let s = state else { return }
        if let uploader = s.uploader {
            await uploader.close()
        }
        // Recreate the uploader so subsequent events keep flowing.
        s.uploader = s.makeUploader()
    }

    /// Typed form of the most recent experiment assignment. Prefer the
    /// value on `FlowSessionStart` / `UpliftFunnelFlowResult`; this static
    /// is a convenience for debug overlays.
    public static var lastExperiment: UpliftFunnelExperimentAssignment? {
        state?.lastExperimentAssignment
    }

    /// Wipe the singleton. Tests-only.
    static func resetForTests() {
        if let s = state {
            s.removeLifecycleObserver()
            let uploader = s.uploader
            Task { await uploader?.close() }
        }
        state = nil
    }

    // MARK: - Private

    private static func require(_ method: String) throws -> FunnelState {
        guard let s = state else {
            throw UpliftFunnelError.notConfigured(method: method)
        }
        return s
    }

    /// For sync registration methods: a debug assertion instead of a thrown
    /// error, keeping call sites `try`-free.
    private static func requireForRegistration(_ method: String) -> FunnelState? {
        guard let s = state else {
            assertionFailure(UpliftFunnelError.notConfigured(method: method)
                .localizedDescription)
            return nil
        }
        return s
    }
}

// MARK: - Internal state

/// Thread-safe identity snapshot read by the uploader's @Sendable providers
/// at serialize time and written by the @MainActor facade.
final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeApiKey: String?
    private var _userId: String?
    private var _anonymousId: String?
    private var _eventContext: [String: JSONValue] = [:]

    var activeApiKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return _activeApiKey }
        set { lock.lock(); defer { lock.unlock() }; _activeApiKey = newValue }
    }
    var userId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _userId }
        set { lock.lock(); defer { lock.unlock() }; _userId = newValue }
    }
    var anonymousId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _anonymousId }
        set { lock.lock(); defer { lock.unlock() }; _anonymousId = newValue }
    }
    var eventContext: [String: JSONValue] {
        get { lock.lock(); defer { lock.unlock() }; return _eventContext }
        set { lock.lock(); defer { lock.unlock() }; _eventContext = newValue }
    }
}

/// Internal state holder. Lives behind `UpliftFunnel` so `resetForTests`
/// can wipe it cleanly.
@MainActor
final class FunnelState {
    static let defaultServerUrl = "https://api.upliftfunnel.com"
    static let anonymousIdKey = "funnel.anonymous_subject_id"
    static let identifiedUserIdKey = "funnel.identified_user_id"
    static let attributionKey = "funnel.attribution"
    static let experimentAssignmentPrefix = "funnel.experiment."
    static let experimentAssignmentSuffix = ".assignment"
    static let attributionKeys: Set<String> = ["source", "campaign", "ad_set", "creative"]
    static let maxAttributionValueLen = 256
    static let eventNameRegex = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_:]*$")

    let apiKey: String
    let serverUrl: String
    let cache: FlowCache
    let fetcher: FlowFetcher
    let urlSession: URLSession
    let defaults: UserDefaults

    let identity = IdentityBox()
    var uploader: EventUploader?
    var lastExperimentAssignment: UpliftFunnelExperimentAssignment?
    var userAttributes: [String: JSONValue] = [:]
    var attribution: [String: String] = [:]
    var appVersion: String?

    /// Host bundle id (auto-detected or passed to `configure`). Sent as
    /// `X-Uplift-Bundle-Id` on every request so the server can pin the API
    /// key to the app it belongs to.
    var bundleId: String?

    var signInHandler: SignInHandler?
    var permissionHandler: PermissionHandler?
    var purchaseHandler: PurchaseHandler?
    var restoreHandler: RestoreHandler?
    var photoUploadHandler: PhotoUploadHandler?
    var linkHandler: LinkHandler?

    /// Schemes `UpliftFunnel.openLink` will forward. Replaced wholesale by
    /// `registerLinkHandler`'s `allowedSchemes`.
    var allowedLinkSchemes: Set<String> = UpliftFunnel.defaultAllowedLinkSchemes

    /// Runtime product catalog, keyed by store product id.
    var products: [String: UpliftFunnelProduct] = [:]

    /// The most recently started flow session, so `track` can attach the
    /// active flow/session/experiment context to app-level events.
    weak var lastBoundSession: FlowSession?
    private var lastBoundToken: UUID?

    /// Per-launch app-session id for `track` events fired outside a flow.
    private var appSessionId: String?

    private var lifecycleTokens: [NSObjectProtocol] = []

    init(
        apiKey: String, serverUrl: String, cache: FlowCache,
        fetcher: FlowFetcher, urlSession: URLSession, defaults: UserDefaults
    ) {
        self.apiKey = apiKey
        self.serverUrl = serverUrl
        self.cache = cache
        self.fetcher = fetcher
        self.urlSession = urlSession
        self.defaults = defaults
    }

    func ensureAppSessionId() -> String {
        if let appSessionId { return appSessionId }
        let id = Identifiers.sessionId()
        appSessionId = id
        return id
    }

    // MARK: Identity / context

    @discardableResult
    func ensureAnonymousId() -> String? {
        if let id = identity.anonymousId { return id }
        var stored = defaults.string(forKey: Self.anonymousIdKey)
        if stored == nil || stored!.isEmpty {
            stored = Identifiers.anonymousId()
            defaults.set(stored, forKey: Self.anonymousIdKey)
        }
        identity.anonymousId = stored
        return stored
    }

    /// Load persisted identity + attribution from disk (survive restarts)
    /// and ensure the anonymous id exists. In-memory values carried across
    /// a config swap win over disk.
    func loadPersistedIdentity() {
        if identity.userId == nil {
            identity.userId = defaults.string(forKey: Self.identifiedUserIdKey)
        }
        if attribution.isEmpty,
           let raw = defaults.string(forKey: Self.attributionKey),
           let decoded = try? JSONValue.parse(raw),
           let obj = decoded.objectValue {
            var restored: [String: String] = [:]
            for (k, v) in obj where Self.attributionKeys.contains(k) {
                restored[k] = v.stringifiedValue ?? v.serializedString()
            }
            attribution = restored
        }
        ensureAnonymousId()
    }

    /// Build the ambient event context from device signals + attribution
    /// and publish it to the identity box for the uploader.
    func rebuildEventContext() {
        var ctx: [String: JSONValue] = [
            "platform": .string(DeviceContext.platform),
            "sdk_version": .string(kUpliftFunnelSdkVersion),
        ]
        if let os = DeviceContext.osVersion, !os.isEmpty {
            ctx["os_version"] = .string(os)
        }
        if let locale = DeviceContext.localeTag, !locale.isEmpty {
            ctx["locale"] = .string(locale)
        }
        if let appVersion, !appVersion.isEmpty {
            ctx["app_version"] = .string(appVersion)
        }
        for key in Self.attributionKeys {
            if let v = attribution[key], !v.isEmpty { ctx[key] = .string(v) }
        }
        identity.eventContext = ctx
    }

    /// Best-effort POST of the anonymous→user mapping to `/v1/identify`.
    /// Failures are swallowed — the server also merges identity implicitly
    /// from events.
    func postIdentify(userId: String, anonymousId: String) {
        guard let key = identity.activeApiKey, !key.isEmpty else { return }
        guard let url = URL(string: "\(serverUrl)/v1/identify") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let bundleId, !bundleId.isEmpty {
            request.setValue(bundleId, forHTTPHeaderField: "X-Uplift-Bundle-Id")
        }
        request.httpBody = try? JSONValue.object([
            "user_id": .string(userId),
            "anonymous_id": .string(anonymousId),
        ]).serializedData()
        let session = urlSession
        Task { _ = try? await session.data(for: request) }
    }

    func makeUploader() -> EventUploader {
        let identity = identity
        // Fixed at configure time (the uploader is rebuilt on every
        // configure), so capturing the value is provider enough.
        let bundleId = bundleId
        // serverUrl passed configure's validation, so this parse is total.
        guard let endpoint = URL(string: "\(serverUrl)/v1/events") else {
            preconditionFailure("UpliftFunnel: invalid serverUrl '\(serverUrl)'")
        }
        return EventUploader(config: EventUploaderConfig(
            endpoint: endpoint,
            apiKeyProvider: { identity.activeApiKey ?? "" },
            bundleIdProvider: { bundleId },
            userIdProvider: { identity.userId },
            anonymousIdProvider: { identity.anonymousId },
            contextProvider: { identity.eventContext },
            queueStore: UserDefaultsEventQueueStore(defaults: defaults),
            urlSession: urlSession))
    }

    // MARK: Experiment assignment persistence

    private func assignmentKey(_ experimentKey: String) -> String {
        Self.experimentAssignmentPrefix + experimentKey + Self.experimentAssignmentSuffix
    }

    /// Persist the last A/B assignment for `experimentKey` so a subsequent
    /// warm-cache start (no assignment header) can still tag events +
    /// surface the variant.
    func persistAssignment(
        _ experimentKey: String, _ assignment: UpliftFunnelExperimentAssignment
    ) {
        defaults.set(
            assignment.toJSON().serializedString(),
            forKey: assignmentKey(experimentKey))
    }

    /// Read the persisted assignment for `experimentKey`, or nil if none /
    /// malformed. Used on warm-cache starts where the header wasn't seen.
    func readPersistedAssignment(_ experimentKey: String)
    -> UpliftFunnelExperimentAssignment? {
        guard let raw = defaults.string(forKey: assignmentKey(experimentKey)),
              !raw.isEmpty,
              let decoded = try? JSONValue.parse(raw) else {
            return nil
        }
        return UpliftFunnelExperimentAssignment.fromJSON(decoded)
    }

    // MARK: Session construction

    func session(
        fromJson json: String,
        userVariables: [String: JSONValue]? = nil,
        experiment: UpliftFunnelExperimentAssignment? = nil,
        flowVersion: Int? = nil
    ) throws -> FlowSession {
        let flow = try FunnelFlow.parse(Data(json.utf8))
        // Product vars (price.X, trial_days.X, ...) go through
        // initialVariables (not contextVariables) because only variables —
        // not context — is readable by {{...}} text interpolation; context
        // is condition-evaluation-only. userVariables spreads last so an
        // explicit value still wins on conflict.
        var initialVariables = productVariables(products.values)
        if let userVariables {
            initialVariables.merge(userVariables) { _, new in new }
        }
        let session = try FlowSession(
            flow: flow,
            initialVariables: initialVariables,
            contextVariables: platformContext(),
            experiment: experiment,
            flowVersion: flowVersion)
        bindUploader(to: session)
        return session
    }

    /// Wire a session's events into the uploader. Only the last bound
    /// session streams — matching the Flutter uploader's single
    /// subscription.
    private func bindUploader(to session: FlowSession) {
        if let token = lastBoundToken, let prev = lastBoundSession {
            prev.removeEventListener(token)
        }
        lastBoundSession = session
        guard let uploader else { return }
        let sessionId = session.sessionId
        let flowId = session.flow.id
        let experiment = session.experiment
        let flowVersion = session.flowVersion
        lastBoundToken = session.addEventListener { [weak uploader] event in
            guard let uploader else { return }
            let payload = uploader.serialize(
                event, sessionId: sessionId, flowId: flowId,
                experiment: experiment, flowVersion: flowVersion)
            Task { await uploader.enqueue(payload) }
        }
    }

    private func platformContext() -> [String: JSONValue] {
        var ctx: [String: JSONValue] = [
            "device.platform": .string(DeviceContext.platform)
        ]
        if let userId = identity.userId { ctx["user.id"] = .string(userId) }
        for (k, v) in userAttributes { ctx["user.\(k)"] = v }
        return ctx
    }

    // MARK: Lifecycle

    /// Flush + persist pending events when the app is backgrounded, so
    /// nothing is lost if the OS then kills the process.
    func registerLifecycleObserver() {
        #if canImport(UIKit) && !os(watchOS)
        let flush: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let uploader = self?.uploader else { return }
                let taskId = UIApplication.shared.beginBackgroundTask()
                await uploader.flushNow()
                if taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                }
            }
        }
        let center = NotificationCenter.default
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main, using: flush))
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main, using: flush))
        #endif
    }

    func removeLifecycleObserver() {
        for token in lifecycleTokens {
            NotificationCenter.default.removeObserver(token)
        }
        lifecycleTokens = []
    }
}
