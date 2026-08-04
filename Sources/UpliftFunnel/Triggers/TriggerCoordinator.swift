import Foundation
#if canImport(UIKit)
import UIKit
#endif

// When to ask, and what to do with the answer.
//
// Three moments justify asking (spec 05 §Ne zaman çağrılır): the app came to
// the front, the host tracked an event the server said it cares about, and a
// flow ended. Nothing polls. On top of that the client holds a 60-second floor
// between calls (spec 15 criterion 5), so a launch that fires several of those
// moments at once still asks once.
//
// ── Nothing is asked of a host that cannot show anything ────────────────────
//
// The coordinator is dormant until a presenter is registered or a slot is
// mounted. An SDK that starts calling a new endpoint on every foreground after
// a version bump would be a behaviour change nobody asked for, and the answer
// would be unusable anyway — there would be nowhere to put it.

/// How the host shows a flow the server decided to open.
///
/// The SDK does not climb into the app's view hierarchy; it asks. That is the
/// deliberate difference from overlay tools (spec 05 §Sunum): they draw on top
/// of the app, this draws where the app makes room.
///
/// Return `false` to decline — the SDK records that the flow was not presented
/// rather than assuming it was, so the frequency cap is not spent on something
/// nobody saw.
@MainActor
public protocol UpliftPresenter: AnyObject {
    /// Show `flowKey` as a full screen. Typically a `fullScreenCover` hosting
    /// `UpliftFunnelFlowView(flowKey:)`.
    func presentFullscreen(flowKey: String, dismissible: Bool) async -> Bool
    /// Show `flowKey` as a sheet.
    func presentSheet(flowKey: String, dismissible: Bool) async -> Bool
}

/// Why an evaluation was requested. Only used for diagnostics and tests.
enum TriggerReason: String, Sendable {
    case foreground
    case tracked
    case flowCompleted
}

/// The floor between two evaluations, spec 15 criterion 5.
let kUpliftTriggerDebounce: TimeInterval = 60

@MainActor
final class TriggerCoordinator {
    private let client: TriggerClient
    private let subjectIdProvider: () -> String
    private let sessionIdProvider: () -> String
    /// Merge the server's profile snapshot under the local one.
    private let onProfileSnapshot: ([String: String]) -> Void

    private weak var presenter: UpliftPresenter?
    /// Slot id → the sink that draws it. A slot registers on appear.
    private var slots: [String: (UpliftTriggerDecision?) -> Void] = [:]

    /// A decision for a slot that was not mounted when it arrived.
    ///
    /// Held rather than refused on the spot: a card decided while the user is
    /// two screens away from its slot should appear when they arrive, and the
    /// alternative is a slot-mode trigger that can only ever fire in the one
    /// second the right screen happens to be visible. It is reported
    /// unpresentable when it is superseded or when the app leaves the front —
    /// spec 15 criterion 6 asks whether the slot was placed, not whether it was
    /// placed at that instant.
    private var pending: UpliftTriggerDecision?

    /// The flow a decision is waiting on, so its completion reports back.
    private var awaitingOutcome: (triggerId: String, flowSlug: String)?

    private(set) var lastEvaluatedAt: Date?
    private var evaluating = false

    /// Event names the server said could change the answer.
    private(set) var evaluateOn: Set<String> = []

    /// Test seam. `Date()` everywhere else.
    var now: () -> Date = Date.init

    init(
        client: TriggerClient,
        subjectIdProvider: @escaping () -> String,
        sessionIdProvider: @escaping () -> String,
        onProfileSnapshot: @escaping ([String: String]) -> Void
    ) {
        self.client = client
        self.subjectIdProvider = subjectIdProvider
        self.sessionIdProvider = sessionIdProvider
        self.onProfileSnapshot = onProfileSnapshot
    }

    // MARK: - Host registration

    func register(presenter: UpliftPresenter) {
        self.presenter = presenter
    }

    /// A slot came on screen. Draws whatever was already decided for it.
    func attach(slot id: String, sink: @escaping (UpliftTriggerDecision?) -> Void) {
        slots[id] = sink
        if let pending, pending.presentation.slot == id {
            self.pending = nil
            deliver(pending, to: sink)
        }
    }

    func detach(slot id: String) {
        slots[id] = nil
    }

    /// True once there is somewhere to put an answer.
    var isActive: Bool { presenter != nil || !slots.isEmpty }

    // MARK: - Evaluation

    /// Ask, unless we asked less than a minute ago.
    ///
    /// `force` exists for one caller: the tests. Nothing in the SDK bypasses
    /// the floor, because the floor is the only thing standing between "the app
    /// came to the front" and a request per view appearance.
    @discardableResult
    func evaluate(
        reason: TriggerReason,
        recentEvents: [(name: String, at: Date)] = [],
        activeFlows: [String] = [],
        force: Bool = false
    ) async -> UpliftTriggerDecision? {
        guard isActive else { return nil }
        guard !evaluating else { return nil }
        let at = now()
        if !force, let last = lastEvaluatedAt, at.timeIntervalSince(last) < kUpliftTriggerDebounce {
            return nil
        }
        let subjectId = subjectIdProvider()
        guard !subjectId.isEmpty else { return nil }

        evaluating = true
        lastEvaluatedAt = at
        defer { evaluating = false }

        let evaluation = await client.evaluate(TriggerEvaluateRequest(
            subjectId: subjectId,
            sessionId: sessionIdProvider(),
            recentEvents: recentEvents,
            activeFlows: activeFlows))

        evaluateOn = evaluation.evaluateOn
        if !evaluation.profile.isEmpty { onProfileSnapshot(evaluation.profile) }

        guard let decision = evaluation.decision else { return nil }
        await present(decision)
        return decision
    }

    /// Should tracking this event name prompt an evaluation?
    func shouldEvaluate(after eventName: String) -> Bool {
        evaluateOn.contains(eventName)
    }

    // MARK: - Presentation

    private func present(_ decision: UpliftTriggerDecision) async {
        // A pending decision that never found its slot is superseded here, and
        // says so rather than disappearing.
        if let stale = pending, stale.triggerId != decision.triggerId {
            pending = nil
            report(stale, unpresentable: .noSlot)
        }

        if decision.presentation.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(decision.presentation.delay * 1_000_000_000))
        }

        switch decision.presentation.mode {
        case .inlineCard, .banner:
            guard let slotId = decision.presentation.slot else {
                report(decision, unpresentable: .noSlot)
                return
            }
            guard let sink = slots[slotId] else {
                // Not refused — held. See `pending`.
                pending = decision
                return
            }
            deliver(decision, to: sink)

        case .fullscreen, .sheet:
            guard let presenter else {
                report(decision, unpresentable: .noPresenter)
                return
            }
            // Wired before presenting: a flow that completes immediately must
            // not find nobody listening for its outcome.
            awaitingOutcome = (decision.triggerId, decision.flowSlug)
            let shown = decision.presentation.mode == .fullscreen
                ? await presenter.presentFullscreen(
                    flowKey: decision.flowSlug,
                    dismissible: decision.presentation.dismissible)
                : await presenter.presentSheet(
                    flowKey: decision.flowSlug,
                    dismissible: decision.presentation.dismissible)
            if !shown {
                awaitingOutcome = nil
                report(decision, unpresentable: .presenterFailed)
            }
        }
    }

    private func deliver(
        _ decision: UpliftTriggerDecision,
        to sink: @escaping (UpliftTriggerDecision?) -> Void
    ) {
        awaitingOutcome = (decision.triggerId, decision.flowSlug)
        sink(decision)
    }

    // MARK: - Outcomes

    /// A flow ended. Reports the outcome if this was the triggered flow, and
    /// asks again either way — a finished flow is call point 3.
    func flowEnded(flowSlug: String?, reason: String) async {
        if let awaiting = awaitingOutcome, awaiting.flowSlug == flowSlug {
            awaitingOutcome = nil
            let outcome = reason == "completed" ? "completed" : "dismissed"
            let triggerId = awaiting.triggerId
            let subjectId = subjectIdProvider()
            let sessionId = sessionIdProvider()
            Task { [client] in
                await client.report(
                    triggerId: triggerId, subjectId: subjectId,
                    sessionId: sessionId, outcome: outcome)
            }
        }
        await evaluate(reason: .flowCompleted)
    }

    /// The app is leaving the front. A decision still waiting for a slot has
    /// run out of chances, and the delivery log should stop claiming it landed.
    func appLeftForeground() {
        guard let stale = pending else { return }
        pending = nil
        report(stale, unpresentable: .noSlot)
    }

    private func report(_ decision: UpliftTriggerDecision, unpresentable reason: UnpresentableReason) {
        let subjectId = subjectIdProvider()
        let sessionId = sessionIdProvider()
        let triggerId = decision.triggerId
        Task { [client] in
            await client.report(
                triggerId: triggerId, subjectId: subjectId, sessionId: sessionId,
                outcome: "unpresentable", reason: reason)
        }
    }

    // MARK: - Test seams

    var pendingDecision: UpliftTriggerDecision? { pending }
    var mountedSlots: Set<String> { Set(slots.keys) }
}
