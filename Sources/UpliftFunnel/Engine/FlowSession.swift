import Foundation
#if canImport(Combine)
import Combine
#endif

// UI-aware wrapper around FlowEngine, ported from the Flutter SDK's
// `engine/flow_session.dart`. Exposes the current screen via @Published so
// SwiftUI rebuilds reactively, and a listener list of high-level FlowEvents
// for analytics and host-app side effects.

/// High-level event emitted while a flow session runs. The event uploader
/// serializes these into the `/v1/events` wire shape.
public enum FlowEvent: Sendable {
    case started(flowId: String, timestamp: Date, entryScreenId: String)
    case screenChanged(flowId: String, timestamp: Date, from: String, to: String)
    /// Screen the value was set on lets analytics break selections down per
    /// screen (e.g. "what % picked each choice option").
    case variableSet(flowId: String, timestamp: Date, screenId: String,
                     name: String, value: JSONValue)
    case custom(flowId: String, timestamp: Date, name: String,
                variables: [String: JSONValue])
    /// One step of a paywall purchase handoff: `attempted`, `succeeded`,
    /// `cancelled`, `failed` or `pending`. Emitted by the render host around
    /// the registered purchase handler, so paywall drop-off is measurable
    /// server-side independently of the billing provider's webhooks.
    case purchase(flowId: String, timestamp: Date, stage: String,
                  screenId: String, planId: String?, productId: String?)
    /// Reason "completed"/"completed:<x>" uploads as `flow_completed`;
    /// anything else as `flow_abandoned`.
    case completed(flowId: String, timestamp: Date, reason: String,
                   variables: [String: JSONValue])
}

@MainActor
public final class FlowSession: ObservableObject {
    private let engine: FlowEngine

    @Published public private(set) var currentScreen: FunnelScreen
    @Published public private(set) var completed: Bool = false

    /// Whether a back affordance should show for `currentScreen`.
    ///
    /// STORED, not computed off `engine.history`: the engine grows history
    /// inside `advance()` a beat before `currentScreen` is published, so a
    /// computed read could be observed by a render pass that still holds the
    /// OLD screen — popping the chevron onto the outgoing screen (and shoving
    /// its content down by the chrome-bar height) before the transition ran.
    /// Publishing it in the same mutation as `currentScreen` makes the two
    /// impossible to observe out of step.
    @Published public private(set) var canGoBack: Bool = false

    /// Stable identifier for this session — every event emitted gets it
    /// attached so analytics can group by funnel walk.
    public let sessionId: String

    /// The A/B assignment this session was started under, or nil for a plain
    /// (non-experiment) start. When present, the event uploader tags every
    /// event of this session with the experiment/variant ids.
    public let experiment: UpliftFunnelExperimentAssignment?

    /// Published version of the flow JSON this session rendered, echoed on
    /// every event. Nil for experiment sessions (the variant id already pins
    /// content) and when served by a pre-analytics API.
    public let flowVersion: Int?

    private var listeners: [UUID: (FlowEvent) -> Void] = [:]

    public init(
        flow: FunnelFlow,
        initialVariables: [String: JSONValue]? = nil,
        contextVariables: [String: JSONValue]? = nil,
        sessionId: String? = nil,
        experiment: UpliftFunnelExperimentAssignment? = nil,
        flowVersion: Int? = nil
    ) throws {
        self.engine = try FlowEngine(
            flow: flow,
            initialVariables: initialVariables,
            contextVariables: contextVariables)
        self.currentScreen = engine.currentScreen
        self.sessionId = sessionId ?? Identifiers.sessionId()
        self.experiment = experiment
        self.flowVersion = flowVersion
        syncCanGoBack()
        // Defer so listeners attached synchronously after the initializer
        // (the typical case in views and tests) actually observe the start
        // event — the analog of Flutter's microtask.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.emit(.started(
                flowId: flow.id,
                timestamp: Date(),
                entryScreenId: flow.entryScreenId))
        }
    }

    public var flow: FunnelFlow { engine.flow }

    public var variables: [String: JSONValue] { engine.variables }

    /// Recompute `canGoBack` from engine state. MUST be called in the same
    /// synchronous mutation that publishes `currentScreen`/`completed`.
    private func syncCanGoBack() {
        let next = !engine.history.isEmpty && !engine.isComplete
        if canGoBack != next { canGoBack = next }
    }

    /// Whether the most recent screen change was a `goBack()`. The session
    /// view reads this to mirror the slide animation on back navigation; it
    /// resets to `false` on every forward step (advance / jump).
    public private(set) var lastNavWasBack = false

    /// Names written via `setVariableLocal` since the last flush, mapped to
    /// the screen they were written on. Flushed to single `variableSet`
    /// events (latest value wins) on navigation/completion.
    private var dirtyVars: [String: String] = [:]

    /// Register a listener for flow events. Keep the returned token and pass
    /// it to `removeEventListener` to unsubscribe.
    @discardableResult
    public func addEventListener(_ listener: @escaping (FlowEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    public func removeEventListener(_ token: UUID) {
        listeners[token] = nil
    }

    /// Set a variable from a view (e.g., user picked an option).
    /// Does NOT advance — call `advance()` separately, or pass
    /// `andAdvance: true`.
    public func setVariable(
        _ name: String, _ value: JSONValue, andAdvance: Bool = false
    ) {
        do {
            try engine.setVariable(name, value)
        } catch {
            assertionFailure("\(error)")
            return
        }
        // A committed write supersedes any pending local writes for the name.
        dirtyVars[name] = nil
        emit(.variableSet(
            flowId: flow.id, timestamp: Date(),
            screenId: engine.currentScreenId, name: name, value: value))
        objectWillChange.send()
        if andAdvance { advance() }
    }

    /// Set a variable WITHOUT emitting an analytics event — the
    /// per-keystroke path for typed/dragged inputs (text, number, slider).
    /// Engine state and `enabled_when` gating update in realtime; the single
    /// `variableSet` for the final value is emitted on the next flush
    /// (navigation, completion, or editing end), so analytics records what
    /// the user submitted, not every character.
    public func setVariableLocal(_ name: String, _ value: JSONValue) {
        // Re-writing the already-committed value (e.g. a focus-loss commit
        // right after a navigation flush) must not re-dirty the name — that
        // would produce a duplicate variable_set.
        if dirtyVars[name] == nil, engine.variables[name] == value { return }
        do {
            try engine.setVariable(name, value)
        } catch {
            assertionFailure("\(error)")
            return
        }
        dirtyVars[name] = engine.currentScreenId
        objectWillChange.send()
    }

    /// Flush the pending local write for `name` only (analytics commit on
    /// editing end / thumb release). No-op when the name isn't dirty, so a
    /// commit that races a navigation flush can't double-emit.
    public func commitVariable(_ name: String) {
        guard let screenId = dirtyVars.removeValue(forKey: name) else { return }
        emit(.variableSet(
            flowId: flow.id, timestamp: Date(),
            screenId: screenId, name: name,
            value: engine.variables[name] ?? .null))
    }

    /// Emit one `variableSet` per pending local write (latest engine value,
    /// attributed to the screen the value was written on) and clear the set.
    public func flushPendingVariableSets() {
        guard !dirtyVars.isEmpty else { return }
        let pending = dirtyVars
        dirtyVars.removeAll()
        for (name, screenId) in pending {
            emit(.variableSet(
                flowId: flow.id, timestamp: Date(),
                screenId: screenId, name: name,
                value: engine.variables[name] ?? .null))
        }
    }

    /// Advance based on the current screen's transition rules.
    public func advance() {
        // Commit typed values first so ordering stays `variable_set` →
        // `screen_changed` and the value attributes to the authoring screen.
        flushPendingVariableSets()
        let fromId = engine.currentScreenId
        let step: EngineStep
        do {
            step = try engine.advance()
        } catch {
            // An authoring error (no matching transition, bad comparison)
            // must not crash the host app — the CTA just doesn't fire.
            assertionFailure("\(error)")
            return
        }
        lastNavWasBack = false
        apply(step, from: fromId)
    }

    /// Step backwards in history. No-op if not possible.
    @discardableResult
    public func goBack() -> Bool {
        flushPendingVariableSets()
        let ok = engine.goBack()
        if ok {
            lastNavWasBack = true
            currentScreen = engine.currentScreen
            syncCanGoBack()
        }
        return ok
    }

    /// Dispatch a primitive-tree action string — the `action` a button/choice
    /// node fires. Recognized forms:
    ///
    ///   - `next` / `submit` — evaluate transitions, same as `advance()`.
    ///   - `back` — same as `goBack()`.
    ///   - `go:<id>` — jump straight to screen `<id>`, bypassing transitions.
    ///   - `end:<reason>` — end the flow immediately with `<reason>`.
    ///   - anything else (including `url:…`) — emitted as a custom event so
    ///     host code can react (e.g. launch a URL).
    /// Runs `action`, ignoring it when it was raised by a screen the user has
    /// already left.
    ///
    /// Timed actions — a progress node's advance, an `AdvanceAfter` timeout —
    /// are scheduled while a screen is on-screen but fire later, and
    /// `advance()` is not idempotent: two `next` calls step two screens,
    /// silently skipping one. Passing `fromScreenId` makes a stale timer a
    /// no-op instead. Omit it for direct user input, which is by definition
    /// current.
    public func handleAction(_ action: String, fromScreenId: String? = nil) {
        if let fromScreenId, fromScreenId != engine.currentScreenId { return }
        switch action {
        case "next", "submit":
            advance()
        case "back":
            goBack()
        default:
            if action.hasPrefix("go:") {
                jumpTo(String(action.dropFirst(3)))
            } else if action.hasPrefix("end:") {
                complete(String(action.dropFirst(4)))
            } else if action.hasPrefix("set:") {
                setLiteral(String(action.dropFirst(4)))
            } else {
                emitCustom(action)
            }
        }
    }

    /// `set:<var>=<value>` — write a literal to a declared variable.
    ///
    /// The action that makes a "choose this and move on" card possible: a tab
    /// that both selects itself and sets the plan its panel sells, a card that
    /// answers a question by being tapped. It does NOT navigate, so it composes
    /// with whatever else the node's action list carries.
    ///
    /// The value is typed from the DECLARATION, not guessed from the text:
    /// `set:count=3` on a number variable must not store the string "3", or
    /// every later comparison against it fails.
    private func setLiteral(_ assignment: String) {
        guard let split = assignment.firstIndex(of: "=") else { return }
        let name = String(assignment[assignment.startIndex..<split])
        let raw = String(assignment[assignment.index(after: split)...])
        guard !name.isEmpty else { return }

        let declared = flow.variables.first { $0.name == name }?.type
        let value: JSONValue
        switch declared {
        case .number:
            guard let n = Double(raw) else { return }
            value = .number(n)
        case .boolean:
            value = .bool(raw == "true")
        default:
            value = .string(raw)
        }
        setVariable(name, value)
    }

    private func jumpTo(_ screenId: String) {
        flushPendingVariableSets()
        let fromId = engine.currentScreenId
        let step: EngineStep
        do {
            step = try engine.jumpTo(screenId)
        } catch {
            assertionFailure("\(error)")
            return
        }
        lastNavWasBack = false
        apply(step, from: fromId)
    }

    /// End the flow immediately with `reason`, bypassing transition
    /// evaluation. Used for primitive-tree `end:<reason>` actions.
    public func complete(_ reason: String) {
        flushPendingVariableSets()
        let step = engine.complete(reason)
        if completed { return }
        completed = true
        syncCanGoBack()
        if case .completed(let effective) = step {
            emit(.completed(
                flowId: flow.id, timestamp: Date(),
                reason: effective, variables: variables))
        }
    }

    /// Fire a custom event (e.g., paywall handoff). Does not affect engine
    /// state.
    public func emitCustom(_ name: String) {
        emit(.custom(
            flowId: flow.id, timestamp: Date(),
            name: name, variables: variables))
    }

    /// Record one step of a purchase handoff. Does not affect engine state —
    /// advancing on success stays the host's call.
    public func trackPurchase(stage: String, planId: String?, productId: String?) {
        emit(.purchase(
            flowId: flow.id, timestamp: Date(), stage: stage,
            screenId: engine.currentScreenId,
            planId: planId, productId: productId))
    }

    /// Forcefully end the flow with a reason. Used when the host dismisses
    /// the onboarding sheet (treated as 'abandoned' unless overridden).
    public func abandon(_ reason: String = "abandoned") {
        if completed { return }
        flushPendingVariableSets()
        completed = true
        emit(.completed(
            flowId: flow.id, timestamp: Date(),
            reason: reason, variables: variables))
    }

    // MARK: - Private

    private func apply(_ step: EngineStep, from fromId: String) {
        switch step {
        case .advanced(let screenId):
            currentScreen = engine.currentScreen
            syncCanGoBack()
            emit(.screenChanged(
                flowId: flow.id, timestamp: Date(),
                from: fromId, to: screenId))
        case .completed(let reason):
            if completed { return }
            completed = true
            syncCanGoBack()
            emit(.completed(
                flowId: flow.id, timestamp: Date(),
                reason: reason, variables: variables))
        }
    }

    private func emit(_ event: FlowEvent) {
        for listener in listeners.values {
            listener(event)
        }
    }
}
