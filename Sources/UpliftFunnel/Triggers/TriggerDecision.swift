import Foundation

// What the server decided, and how the host is asked to show it.
//
// The client carries no rules. It reports where it is and what just happened,
// and the server answers with a flow key and a presentation — which is what
// makes "change when this appears" a dashboard edit rather than an App Store
// release. Everything in this file is a decoded answer; nothing in it decides.

/// Where a triggered flow is meant to appear.
public enum UpliftPresentationMode: String, Sendable {
    /// The existing full-screen path — `UpliftFunnelFlowView`.
    case fullscreen
    /// A modal sheet the host presents over its own UI.
    case sheet
    /// Drawn inside a slot the host placed, as a card.
    case inlineCard = "inline_card"
    /// Drawn inside a slot the host placed, as a banner.
    case banner

    /// An unknown mode is not a crash and not a guess.
    ///
    /// A server that learns a fifth mode will send it to SDKs that predate it,
    /// and the honest client behaviour is to decline: rendering a `toast` as a
    /// full screen would put a flow somewhere its author never agreed to.
    /// Invariant I30's shape — degrade, never invent.
    static func decode(_ raw: String?) -> UpliftPresentationMode? {
        guard let raw else { return nil }
        return UpliftPresentationMode(rawValue: raw)
    }
}

/// How a decided flow should be presented.
public struct UpliftPresentation: Sendable, Equatable {
    public let mode: UpliftPresentationMode
    /// Which host-declared slot to draw into. Non-nil for `inlineCard`/`banner`.
    public let slot: String?
    /// Whether the user may close it. Always true for `fullscreen`.
    public let dismissible: Bool
    /// How long after the decision to show it.
    public let delay: TimeInterval

    public init(
        mode: UpliftPresentationMode, slot: String? = nil,
        dismissible: Bool = true, delay: TimeInterval = 0
    ) {
        self.mode = mode
        self.slot = slot
        self.dismissible = dismissible
        self.delay = delay
    }
}

/// The server's answer to "what should I show right now".
public struct UpliftTriggerDecision: Sendable, Equatable {
    public let triggerId: String
    public let flowSlug: String
    public let presentation: UpliftPresentation
}

/// The whole response, including the parts that are true whether or not a
/// trigger fired.
struct TriggerEvaluation: Sendable {
    /// Nil when nothing fired — the common answer, and not an error.
    let decision: UpliftTriggerDecision?

    /// The server's view of what this person has answered, across devices and
    /// reinstalls. Merged under the local profile, never over it.
    let profile: [String: String]

    /// Event types that could change the answer, so `track()` knows which of
    /// its calls are worth re-asking after (spec 05 §Ne zaman çağrılır).
    ///
    /// From the server rather than the app, because a new rule about a new
    /// event has to start working without a release — the same reason the rules
    /// themselves are not on the device.
    let evaluateOn: Set<String>

    static let empty = TriggerEvaluation(decision: nil, profile: [:], evaluateOn: [])

    /// Decode, tolerating everything a future server might add.
    ///
    /// A field this SDK version does not know is skipped rather than fatal: the
    /// event envelope has been forward-compatible since 0.6 (I29) and an answer
    /// that fails to parse would take the whole trigger surface down for hosts
    /// that cannot update.
    static func decode(_ value: JSONValue) -> TriggerEvaluation {
        guard let object = value.objectValue else { return .empty }

        var profile: [String: String] = [:]
        for (key, entry) in object["profile"]?.objectValue ?? [:] {
            // `stringifiedValue` so a numeric or boolean answer arrives the way
            // `{{...}}` would print it — the profile is strings on this side,
            // and a host comparing `profile("age") == "30"` must not depend on
            // whether the server stored 30 or "30".
            if let text = entry.stringifiedValue { profile[key] = text }
        }

        var evaluateOn = Set<String>()
        for entry in object["evaluate_on"]?.arrayValue ?? [] {
            if let name = entry.stringValue, !name.isEmpty { evaluateOn.insert(name) }
        }

        guard
            let triggerId = object["trigger_id"]?.stringValue, !triggerId.isEmpty,
            let flowSlug = object["flow_slug"]?.stringValue, !flowSlug.isEmpty,
            let presentation = decodePresentation(object["presentation"])
        else {
            return TriggerEvaluation(
                decision: nil, profile: profile, evaluateOn: evaluateOn)
        }

        return TriggerEvaluation(
            decision: UpliftTriggerDecision(
                triggerId: triggerId, flowSlug: flowSlug,
                presentation: presentation),
            profile: profile,
            evaluateOn: evaluateOn)
    }

    private static func decodePresentation(_ value: JSONValue?) -> UpliftPresentation? {
        guard let object = value?.objectValue,
              let mode = UpliftPresentationMode.decode(object["mode"]?.stringValue)
        else { return nil }

        let slot = object["slot"]?.stringValue
        // A slot mode with no slot names nowhere to draw. Declining here means
        // the coordinator reports `no_slot` rather than silently doing nothing.
        if (mode == .inlineCard || mode == .banner) && (slot?.isEmpty ?? true) {
            return nil
        }

        let delayMs = object["delayMs"]?.intValue ?? 0
        return UpliftPresentation(
            mode: mode,
            slot: (mode == .inlineCard || mode == .banner) ? slot : nil,
            // Full screen is always closable; the server says so too, and
            // agreeing here means a stale field can never trap somebody.
            dismissible: mode == .fullscreen ? true : (object["dismissible"]?.boolValue ?? true),
            delay: Double(max(0, delayMs)) / 1000)
    }
}

/// Why a decision could not be shown. Closed set — the server groups on it.
enum UnpresentableReason: String, Sendable {
    /// `inline_card`/`banner` for a slot the host never placed (spec 15 §6).
    case noSlot = "no_slot"
    /// No presenter registered, so there is nobody to show a sheet or a screen.
    case noPresenter = "no_presenter"
    /// The presenter was called and refused.
    case presenterFailed = "presenter_failed"
}
