import Foundation

// Pure (UI-free) state machine that drives an Uplift Funnel onboarding flow.
// Ported from the Flutter SDK's `engine/flow_engine.dart`.
//
// Responsibilities:
//   - Track the current screen and collected variables.
//   - Evaluate per-screen transition rules to determine the next screen.
//   - Honor terminal transitions (`end:<reason>`).
//   - Support back navigation through a history stack.

public enum EngineStep: Equatable, Sendable {
    case advanced(screenId: String)
    /// Reason is whatever the flow author put after `end:` in the
    /// transition's `go` field — e.g. "completed", "abandoned", "skipped".
    case completed(reason: String)
}

public final class FlowEngine {
    public let flow: FunnelFlow

    private var _variables: [String: JSONValue]
    private let context: [String: JSONValue]
    private var _history: [String] = []
    private var _currentScreenId: String
    private var _completionReason: String?

    public init(
        flow: FunnelFlow,
        initialVariables: [String: JSONValue]? = nil,
        contextVariables: [String: JSONValue]? = nil
    ) throws {
        self.flow = flow
        self._variables = initialVariables ?? [:]
        self.context = contextVariables ?? [:]
        self._currentScreenId = flow.entryScreenId
        // Validate that entry_screen_id resolves; fail loudly.
        _ = try Self.screen(in: flow, id: flow.entryScreenId)
    }

    /// Currently rendered screen.
    public var currentScreen: FunnelScreen {
        // The id is only ever set through validated paths, so this cannot miss.
        flow.screen(byId: _currentScreenId)!
    }

    public var currentScreenId: String { _currentScreenId }

    /// Read-only view of variables collected so far.
    public var variables: [String: JSONValue] { _variables }

    /// History of screen ids visited (excludes current). Used for back nav.
    public var history: [String] { _history }

    public var isComplete: Bool { _completionReason != nil }

    public var completionReason: String? { _completionReason }

    /// Set a variable. Idempotent: setting the same name twice overwrites.
    public func setVariable(_ name: String, _ value: JSONValue) throws {
        if isComplete {
            throw FlowEngineError("Cannot set variable on a completed flow.")
        }
        _variables[name] = value
    }

    /// Run transition rules in order. Returns the resulting step.
    ///
    /// Throws `FlowEngineError` if no rule matches and there's no default.
    public func advance() throws -> EngineStep {
        if let reason = _completionReason {
            return .completed(reason: reason)
        }

        let screen = currentScreen
        let transitions = screen.transitions

        if transitions.isEmpty {
            // Finale or any screen with no outgoing transitions — implicitly
            // complete.
            return terminate("completed")
        }

        for t in transitions {
            let matches = try t.condition.map { try evaluate($0) } ?? true
            guard matches else { continue }

            if t.isTerminal {
                return terminate(t.terminalReason ?? "completed")
            }
            return try advanceTo(t.go)
        }

        throw FlowEngineError(
            "No transition matched on screen \"\(screen.id)\" and no default "
            + "fall-through was provided. Variables at decision time: \(_variables)")
    }

    /// Pop the history stack. Returns true if a back step actually happened.
    @discardableResult
    public func goBack() -> Bool {
        if _history.isEmpty || isComplete { return false }
        _currentScreenId = _history.removeLast()
        return true
    }

    /// Jump straight to `screenId`, bypassing transition evaluation. Used by
    /// primitive-tree `go:<id>` actions. Throws when the target doesn't exist
    /// or the flow is already complete.
    public func jumpTo(_ screenId: String) throws -> EngineStep {
        if isComplete {
            throw FlowEngineError("Cannot jump to a screen on a completed flow.")
        }
        return try advanceTo(screenId)
    }

    /// End the flow immediately with `reason`, bypassing transition
    /// evaluation entirely. Used by primitive-tree `end:<reason>` actions.
    @discardableResult
    public func complete(_ reason: String) -> EngineStep {
        if let existing = _completionReason {
            return .completed(reason: existing)
        }
        return terminate(reason)
    }

    // MARK: - Private

    private func advanceTo(_ screenId: String) throws -> EngineStep {
        // Validate target exists.
        _ = try Self.screen(in: flow, id: screenId)
        _history.append(_currentScreenId)
        _currentScreenId = screenId
        return .advanced(screenId: screenId)
    }

    private func terminate(_ reason: String) -> EngineStep {
        _completionReason = reason
        return .completed(reason: reason)
    }

    private static func screen(in flow: FunnelFlow, id: String) throws -> FunnelScreen {
        guard let screen = flow.screen(byId: id) else {
            throw FlowEngineError("No screen with id \"\(id)\" in flow \"\(flow.id)\"")
        }
        return screen
    }

    // MARK: - Condition evaluation

    private func evaluate(_ c: FunnelCondition) throws -> Bool {
        try evaluateCondition(c) { [weak self] name in self?.readVariable(name) }
    }

    private func readVariable(_ name: String) -> JSONValue? {
        // Context vars are dotted (device.platform, user.is_returning).
        if name.contains(".") {
            return context[name]
        }
        return _variables[name]
    }
}
