import Foundation

// Purchase handoff contract for `purchase` button actions on paywall
// screens, ported from the Flutter SDK's `purchase.dart`.

/// Outcome of the host app's billing flow for one `purchase` tap.
///
/// Only `.purchased` advances the flow. The others keep the user on the
/// paywall — and each is tracked as its own analytics event
/// (`purchase_succeeded` / `purchase_cancelled` / `purchase_failed` /
/// `purchase_pending`), so paywall drop-off is measurable server-side.
public enum PurchaseResult: String, Sendable {
    /// The transaction completed — the flow's default transition fires.
    case purchased
    /// The user dismissed the store sheet. Not an error; don't surface one.
    case cancelled
    /// The transaction errored (billing unavailable, payment declined, ...).
    case failed
    /// The transaction needs external approval (e.g. StoreKit "Ask to Buy").
    /// The flow does not advance; grant it later via your billing provider's
    /// entitlement check.
    case pending
}

/// Everything the SDK knows about a `purchase` tap, handed to the host's
/// `PurchaseHandler`.
public struct PurchaseRequest: Sendable {
    /// Flow JSON `id` of the funnel the tap happened in — branch on this
    /// when different funnels sell differently.
    public let flowId: String

    /// Screen the purchase button lives on.
    public let screenId: String

    /// Analytics session id, for correlating with server-side events.
    public let sessionId: String

    /// Selected plan `id` from the screen's `plan_picker` (the value written
    /// to its bound variable), or nil when the screen has no picker /
    /// nothing was picked.
    public let planId: String?

    /// Store product identifier for the selected plan, already resolved for
    /// the current platform: the `product_id_ios` override wins, else the
    /// plan's `product_id`. Nil when the plan declares none — fall back to
    /// mapping `planId` yourself.
    public let productId: String?

    /// Raw plan JSON as authored in the dashboard (label/price/period/badge/
    /// product ids...), or nil when no plan matched. Escape hatch for hosts
    /// that need more than `productId`.
    public let plan: JSONValue?

    public init(
        flowId: String, screenId: String, sessionId: String,
        planId: String? = nil, productId: String? = nil, plan: JSONValue? = nil
    ) {
        self.flowId = flowId
        self.screenId = screenId
        self.sessionId = sessionId
        self.planId = planId
        self.productId = productId
        self.plan = plan
    }
}

/// Host-side purchase handoff. Runs the real billing flow (RevenueCat,
/// Adapty, StoreKit, ...) for `request.productId` (or `request.planId`) and
/// resolves to the outcome — only `.purchased` advances the flow. Without a
/// handler `purchase` simply advances, so paywall screens are inert until
/// billing is wired up.
public typealias PurchaseHandler = @MainActor (PurchaseRequest) async -> PurchaseResult
