import Foundation
import Observation

/// SwiftUI-aware wrapper over [FlowEngine]. Exposes the current screen
/// and completion state via `@Observable` so views re-render reactively;
/// fires `FlowEvent`s through an `AsyncStream` for analytics callers.

public enum FlowEvent: Sendable {
    case started(flowId: String, entryScreenId: String, timestamp: Date)
    case screenChanged(flowId: String, from: String, to: String, timestamp: Date)
    case variableSet(flowId: String, name: String, value: AnyHashable?, timestamp: Date)
    case customEvent(flowId: String, name: String, variables: [String: AnyHashable], timestamp: Date)
    case completed(flowId: String, reason: String, variables: [String: AnyHashable], timestamp: Date)
}

@MainActor
@Observable
public final class FlowSession {
    private let engine: FlowEngine
    public let sessionId: String
    public private(set) var currentScreen: FunnelScreen
    public private(set) var isComplete: Bool = false

    private var continuations: [AsyncStream<FlowEvent>.Continuation] = []

    public init(
        flow: Flow,
        initialVariables: [String: AnyHashable] = [:],
        contextVariables: [String: AnyHashable] = [:],
        sessionId: String? = nil
    ) throws {
        self.engine = try FlowEngine(
            flow: flow,
            initialVariables: initialVariables,
            contextVariables: contextVariables
        )
        self.currentScreen = engine.currentScreen
        self.sessionId = sessionId ?? Self.generateSessionId()

        // Defer the started event so subscribers attached after construction
        // (the typical case) actually observe it.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.emit(.started(
                flowId: flow.id,
                entryScreenId: flow.entryScreenId,
                timestamp: Date()
            ))
        }
    }

    public var flow: Flow { engine.flow }
    public var variables: [String: AnyHashable] { engine.variables }
    public var canGoBack: Bool { !engine.history.isEmpty && !isComplete }

    public var events: AsyncStream<FlowEvent> {
        AsyncStream { continuation in
            self.continuations.append(continuation)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeAll { $0.onTermination == nil }
                }
            }
        }
    }

    public func setVariable(_ name: String, _ value: AnyHashable?, advance: Bool = false) throws {
        try engine.setVariable(name, value)
        emit(.variableSet(
            flowId: flow.id, name: name, value: value, timestamp: Date()
        ))
        if advance { try self.advance() }
    }

    public func advance() throws {
        let from = engine.currentScreenId
        let step = try engine.advance()
        switch step {
        case .advanced(let to):
            currentScreen = engine.currentScreen
            emit(.screenChanged(
                flowId: flow.id, from: from, to: to, timestamp: Date()
            ))
        case .completed(let reason):
            isComplete = true
            emit(.completed(
                flowId: flow.id,
                reason: reason,
                variables: variables,
                timestamp: Date()
            ))
        }
    }

    @discardableResult
    public func goBack() -> Bool {
        let ok = engine.goBack()
        if ok { currentScreen = engine.currentScreen }
        return ok
    }

    public func emitCustom(_ name: String) {
        emit(.customEvent(
            flowId: flow.id, name: name, variables: variables, timestamp: Date()
        ))
    }

    public func abandon(reason: String = "abandoned") {
        if isComplete { return }
        isComplete = true
        emit(.completed(
            flowId: flow.id, reason: reason, variables: variables, timestamp: Date()
        ))
    }

    // MARK: - Internals

    private func emit(_ event: FlowEvent) {
        for c in continuations { c.yield(event) }
    }

    private static func generateSessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            return "sess_\(UUID().uuidString.lowercased())"
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "sess_\(hex)"
    }

    /// Drain the AsyncStream subscribers. Call before discarding the session
    /// — Swift 6's main-actor isolation prevents this from running in deinit.
    public func close() {
        for c in continuations { c.finish() }
        continuations.removeAll()
    }
}
