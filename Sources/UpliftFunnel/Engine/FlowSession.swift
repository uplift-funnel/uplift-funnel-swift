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
    ///
    /// `priceAmount`/`currencyCode` come from the product the host published
    /// through `setProducts`, and only ride along on `succeeded`. The
    /// authoritative revenue record stays `revenue_events` on the server; this
    /// is the rough signal for accounts with no billing provider connected yet.
    case purchase(flowId: String, timestamp: Date, stage: String,
                  screenId: String, planId: String?, productId: String?,
                  priceAmount: Double? = nil, currencyCode: String? = nil)
    /// How long a screen took to become visible, and then to stop changing.
    /// `phase` is `first_paint` or `interactive`.
    case renderTime(flowId: String, timestamp: Date, screenId: String,
                    ms: Int, phase: String)
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

    // ── inference ────────────────────────────────────────────────────────────
    //
    // Caught here rather than in the render host, where `permission:` lives,
    // and that is not a preference: spec 15 criterion 1 says no item of that
    // spec changes the render pipeline, and an architecture test holds the
    // `Render/` and `UpliftLayout/` diffs empty. The engine is where `go:` and
    // `set:` are already handled, so `infer:` and `consent:` belong next to
    // them anyway.

    /// Set by `UpliftFunnel` when a flow starts. Nil means inference is
    /// unavailable — an `infer:` action then applies its fallback immediately
    /// rather than hanging, which is the same answer a dead network gives.
    var inference: InferenceEnvironment?

    /// The flow slug this session was served under. The server resolves the
    /// inference behavior from the document, and this is how it finds it.
    var flowSlug: String = ""

    /// Ids with a run in flight, so a double-tap starts one job rather than
    /// two. The server would deduplicate anyway (one idempotency key, one
    /// charge), but a second in-flight run would race to write the same
    /// variables and the loser's answer would win at random.
    private var inferencesRunning: Set<String> = []

    /// Ids that have been started at least once, by any route.
    ///
    /// Written by manual `infer:` taps too, not just by auto-start, and that is
    /// the point: a CTA that starts a job and then navigates to the loading
    /// screen carrying the same aspect would otherwise run it twice. The server
    /// deduplicates on the idempotency key so it would cost one charge, but it
    /// is still two round trips and two races to write the same variables.
    /// A second explicit tap — a "try again" button — is still honoured.
    private var autoStarted: Set<String> = []

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
            // Seed before auto-start: a status token on the entry screen has to
            // read `idle` rather than its own braces, and the entry screen is
            // allowed to be the one that carries the aspect.
            self.seedInferenceStatuses()
            self.autoStartInferencesForCurrentScreen()
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
            } else if action.hasPrefix("infer:") {
                startInference(String(action.dropFirst("infer:".count)))
            } else if action.hasPrefix("consent:") {
                recordConsent(String(action.dropFirst("consent:".count)))
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

    // MARK: - inference

    /// Every `behavior.inference` in the flow, by id.
    ///
    /// Walks the whole document rather than one screen, because `infer:<id>`
    /// resolves flow-wide: the tap that starts a job and the screen that shows
    /// its result are usually two different screens, with a loading screen in
    /// between.
    private func inferenceSpecs() -> [String: InferenceSpec] {
        var out: [String: InferenceSpec] = [:]
        for screen in flow.screens {
            for raw in Self.findInferences(screen.root) {
                guard let spec = InferenceSpec.decode(raw) else { continue }
                if out[spec.id] == nil { out[spec.id] = spec }
            }
        }
        return out
    }

    /// Depth-first search for `behavior.inference` dictionaries.
    ///
    /// Walks every object value rather than only `children`, the same way the
    /// server's resolver and the schema's rules do: an aspect can sit on a node
    /// nested inside props, and a search that only knows `children` finds a
    /// subset and reports the rest as missing.
    private static func findInferences(_ value: JSONValue) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ node: JSONValue) {
            if let array = node.arrayValue {
                for item in array { walk(item) }
                return
            }
            guard let object = node.objectValue else { return }
            if let behavior = object["behavior"]?.objectValue,
               let inference = behavior["inference"],
               let raw = inference.anyValue as? [String: Any] {
                out.append(raw)
            }
            for child in object.values { walk(child) }
        }
        walk(value)
        return out
    }

    /// Write `inference.<id>.status` and the fields a ready result published.
    ///
    /// Straight to the engine, with no `variable_set` event and no dirty mark:
    /// this is SDK state a waiting screen draws from, not something the user
    /// answered, and emitting it would put engine bookkeeping in the same
    /// analytics stream as the person's own choices. The mapped *outputs* do
    /// emit — the server already recorded them, and they are answers.
    private func setInternal(_ name: String, _ value: JSONValue) {
        try? engine.setVariable(name, value)
    }

    private func setStatus(_ id: String, _ status: InferenceStatus) {
        setInternal("inference.\(id).status", .string(status.rawValue))
        // The condition variable the schema documents, so `transitions` and
        // `visible.when` can branch without a new operator.
        setInternal("inference_\(id)_status", .string(status.rawValue))
        objectWillChange.send()
    }

    /// Seed every declared inference to `idle`.
    ///
    /// Without this the token renders as literal `{{inference.skin.status}}` on
    /// any screen the user reaches before the job starts — the renderer keeps
    /// braces for unresolved names on purpose, and a progress line above the
    /// CTA is a perfectly ordinary design.
    func seedInferenceStatuses() {
        for id in inferenceSpecs().keys where variables["inference.\(id).status"] == nil {
            setStatus(id, .idle)
        }
    }

    /// Start any inference whose aspect sits on the current screen's ROOT node.
    ///
    /// Root only, and that is the spec's rule (04 §Tetikleme): an aspect deeper
    /// in the tree waits for `infer:`. A loading screen declares its work by
    /// carrying it at the top; a button that starts one says so with an action.
    func autoStartInferencesForCurrentScreen() {
        guard let root = currentScreen.root.objectValue,
              let behavior = root["behavior"]?.objectValue,
              let raw = behavior["inference"]?.anyValue as? [String: Any],
              let spec = InferenceSpec.decode(raw),
              !autoStarted.contains(spec.id)
        else { return }
        autoStarted.insert(spec.id)
        startInference(spec.id)
    }

    /// `consent:<id>` — the user agreed to what the screen they are on said.
    ///
    /// Fire-and-forget on purpose. The submit that follows is what actually
    /// needs the record, and the server refuses it with 403 if this did not
    /// land — so a failure here surfaces as the flow's own fallback rather than
    /// as a blocked tap on a screen the user thought they had finished with.
    private func recordConsent(_ id: String) {
        guard let inference, let spec = inferenceSpecs()[id] else { return }
        Task { @MainActor in
            _ = await InferenceRunner.recordConsent(spec: spec, environment: inference)
        }
    }

    /// `infer:<id>` — run it, then write what came back and move on.
    ///
    /// Criterion 4 in one function: every path ends in either the outputs or
    /// the fallback, and both end with the flow advancing. There is no branch
    /// that leaves the user where they were.
    private func startInference(_ id: String) {
        guard let spec = inferenceSpecs()[id] else { return }
        guard !inferencesRunning.contains(id) else { return }

        guard let inference else {
            // Not configured: the same answer a dead network gives, delivered
            // immediately rather than after a timeout nobody benefits from.
            setStatus(id, .failed)
            setInternal("inference.\(id).error", .string("not_configured"))
            applyFallback(spec)
            return
        }

        inferencesRunning.insert(id)
        autoStarted.insert(id)
        setStatus(id, .pending)
        setInternal("inference.\(id).error", .string(""))

        let slug = flowSlug
        let session = sessionId
        let snapshot = variables
        let startedOn = engine.currentScreenId
        Task { @MainActor [weak self] in
            let outcome = await InferenceRunner.run(
                spec: spec, flowSlug: slug, sessionId: session,
                variables: snapshot, environment: inference)
            guard let self else { return }
            self.inferencesRunning.remove(id)
            self.finish(spec: spec, outcome: outcome, startedOn: startedOn)
        }
    }

    private func finish(spec: InferenceSpec, outcome: InferenceOutcome, startedOn: String) {
        // Writing the variables is always right — the answer is about the
        // person, not about where they happen to be standing. Navigating is
        // not: the screen may have moved on, either because the user tapped
        // through or because the same tap carried a `next` after the `infer:`.
        // Advancing again from here would skip a screen nobody saw, and the
        // same staleness guard `handleAction(fromScreenId:)` already uses is
        // the answer.
        let stillHere = engine.currentScreenId == startedOn && !completed
        switch outcome {
        case .ready(let outputs):
            for (name, value) in outputs {
                setInternal("inference.\(spec.id).\(name)", value)
                // The mapped variable is the durable half and the one the rest
                // of the flow was authored against, so it emits like any other
                // answer. The server already wrote its own `variable_set`; the
                // client's carries the same name and value, and ingest
                // deduplicates on the event id.
                setVariable(name, value)
            }
            setStatus(spec.id, .ready)
            if stillHere { advance() }
        case .failed(let code, let message):
            setStatus(spec.id, .failed)
            setInternal("inference.\(spec.id).error", .string(code))
            setInternal("inference.\(spec.id).message", .string(message))
            if stillHere { applyFallback(spec) }
        }
    }

    /// The three shapes, and all three advance.
    private func applyFallback(_ spec: InferenceSpec) {
        switch spec.fallback {
        case .skip:
            advance()
        case .goto(let screenId):
            jumpTo(screenId)
        case .setVariables(let values):
            for (name, value) in values { setVariable(name, value) }
            advance()
        }
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
    public func trackPurchase(
        stage: String, planId: String?, productId: String?,
        priceAmount: Double? = nil, currencyCode: String? = nil
    ) {
        emit(.purchase(
            flowId: flow.id, timestamp: Date(), stage: stage,
            screenId: engine.currentScreenId,
            planId: planId, productId: productId,
            priceAmount: priceAmount, currencyCode: currencyCode))
    }

    /// Record how long a screen took to reach `phase`.
    ///
    /// Called by the render host, which is the only thing that knows when a
    /// screen actually appeared. Measured per screen, not per session: the
    /// question this answers is "which screen is slow", and a session-level
    /// average hides exactly the one that is.
    public func trackRenderTime(screenId: String, ms: Int, phase: String) {
        emit(.renderTime(
            flowId: flow.id, timestamp: Date(),
            screenId: screenId, ms: ms, phase: phase))
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
            // After the event, so a loading screen's `screen_changed` is
            // recorded before the job it exists to wait for starts.
            autoStartInferencesForCurrentScreen()
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
