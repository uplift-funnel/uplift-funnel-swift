import Foundation

/// Pure (UIKit/SwiftUI-free) state machine that drives a Funnel onboarding
/// flow. Mirrors the Dart FlowEngine — same semantics, same condition
/// operators. Tested independently in Tests/FunnelOnboardingTests.

public enum EngineStep: Sendable, Equatable {
    case advanced(screenId: String)
    case completed(reason: String)
}

public struct FlowEngineError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "FlowEngineError: \(message)" }
}

public final class FlowEngine {
    public let flow: Flow
    private(set) public var variables: [String: AnyHashable]
    private let context: [String: AnyHashable]
    private(set) public var history: [String] = []
    private(set) public var currentScreenId: String
    private(set) public var completionReason: String? = nil

    public init(
        flow: Flow,
        initialVariables: [String: AnyHashable] = [:],
        contextVariables: [String: AnyHashable] = [:]
    ) throws {
        self.flow = flow
        self.variables = initialVariables
        self.context = contextVariables
        self.currentScreenId = flow.entryScreenId
        guard flow.screen(byId: flow.entryScreenId) != nil else {
            throw FlowEngineError("entry_screen_id \"\(flow.entryScreenId)\" not found in screens")
        }
    }

    public var currentScreen: FunnelScreen {
        flow.screen(byId: currentScreenId)!
    }

    public var isComplete: Bool { completionReason != nil }

    public func setVariable(_ name: String, _ value: AnyHashable?) throws {
        if isComplete {
            throw FlowEngineError("Cannot set variable on a completed flow")
        }
        if let value = value {
            variables[name] = value
        } else {
            variables.removeValue(forKey: name)
        }
    }

    @discardableResult
    public func advance() throws -> EngineStep {
        if let reason = completionReason { return .completed(reason: reason) }
        let screen = currentScreen
        let transitions = screen.transitions

        if transitions.isEmpty {
            return terminate("completed")
        }

        for t in transitions {
            let matches = t.condition == nil ? true : evaluate(t.condition!)
            if !matches { continue }

            if t.isTerminal {
                return terminate(t.terminalReason ?? "completed")
            }
            return try advanceTo(t.go)
        }

        throw FlowEngineError(
            "No transition matched on screen \"\(screen.id)\" and no default fall-through. Variables: \(variables)"
        )
    }

    @discardableResult
    public func goBack() -> Bool {
        if isComplete || history.isEmpty { return false }
        currentScreenId = history.removeLast()
        return true
    }

    private func advanceTo(_ screenId: String) throws -> EngineStep {
        guard flow.screen(byId: screenId) != nil else {
            throw FlowEngineError("Transition target \"\(screenId)\" not found")
        }
        history.append(currentScreenId)
        currentScreenId = screenId
        return .advanced(screenId: screenId)
    }

    private func terminate(_ reason: String) -> EngineStep {
        completionReason = reason
        return .completed(reason: reason)
    }

    // MARK: Condition evaluator

    private func evaluate(_ c: Condition) -> Bool {
        let value = readVariable(c.varName)
        switch c.op {
        case .isSet: return value != nil
        case .isNotSet: return value == nil
        case .eq: return looseEquals(value, c.value?.value)
        case .neq: return !looseEquals(value, c.value?.value)
        case .gt, .lt, .gte, .lte:
            guard
                let na = asNumber(value),
                let nb = asNumber(c.value?.value)
            else { return false }
            switch c.op {
            case .gt: return na > nb
            case .lt: return na < nb
            case .gte: return na >= nb
            case .lte: return na <= nb
            default: return false
            }
        case .contains:
            return contains(value, c.value?.value)
        case .notContains:
            return !contains(value, c.value?.value)
        }
    }

    private func readVariable(_ name: String) -> AnyHashable? {
        if name.contains(".") {
            return context[name]
        }
        return variables[name]
    }

    private func looseEquals(_ a: AnyHashable?, _ b: AnyHashable?) -> Bool {
        if a == nil || b == nil { return a == nil && b == nil }
        if let na = asNumber(a), let nb = asNumber(b) {
            return na == nb
        }
        return String(describing: a!) == String(describing: b!)
    }

    private func asNumber(_ v: AnyHashable?) -> Double? {
        guard let v = v else { return nil }
        switch v.base {
        case let i as Int: return Double(i)
        case let d as Double: return d
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func contains(_ haystack: AnyHashable?, _ needle: AnyHashable?) -> Bool {
        guard let needle = needle else { return false }
        switch haystack?.base {
        case let arr as [AnyHashable]:
            return arr.contains(needle)
        case let s as String:
            if let nstr = needle.base as? String {
                return s.contains(nstr)
            }
            return false
        default:
            return false
        }
    }
}
