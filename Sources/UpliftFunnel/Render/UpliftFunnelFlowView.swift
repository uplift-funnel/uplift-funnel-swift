import Foundation
import SwiftUI

// One-view entry point, ported from `uplift_funnel_flow.dart` (Flutter's
// `UpliftFunnelFlow` widget): fetch a flow by key, start a session, render
// it behind loading/error states.
//
//   UpliftFunnelFlowView(flowKey: "cal-ai-clone") { result in ... }
//
// For lower-level control (custom loading UI driven from outside, or
// starting a session ahead of time), call `UpliftFunnel.start` directly and
// render the session with `UpliftFunnelSessionView`.

/// Outcome of a flow session, passed to `onCompleted`.
public struct UpliftFunnelFlowResult: Sendable {
    /// The transition reason the flow ended with, e.g. "completed",
    /// "abandoned", "skipped".
    public let endReason: String

    /// All variables collected over the course of the session.
    public let variables: [String: JSONValue]

    /// Where the rendered flow JSON came from — network, cache, or a 304
    /// revalidation. Useful for surfacing "offline mode" UI.
    public let source: FetchSource

    /// The A/B assignment the completed session ran under, or nil for a
    /// non-experiment flow or when no running experiment matched.
    public let experiment: UpliftFunnelExperimentAssignment?
}

public struct UpliftFunnelFlowView: View {
    let flowKey: String
    let isExperiment: Bool
    let onCompleted: ((UpliftFunnelFlowResult) -> Void)?
    let userVariables: [String: JSONValue]?
    let forceRefresh: Bool
    let loadingView: (() -> AnyView)?
    let errorView: ((Error, @escaping () -> Void) -> AnyView)?

    /// Fetches `flowKey`, starts a session, and renders it.
    public init(
        flowKey: String,
        onCompleted: ((UpliftFunnelFlowResult) -> Void)? = nil,
        userVariables: [String: JSONValue]? = nil,
        forceRefresh: Bool = false,
        loadingView: (() -> AnyView)? = nil,
        errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil
    ) {
        self.flowKey = flowKey
        self.isExperiment = false
        self.onCompleted = onCompleted
        self.userVariables = userVariables
        self.forceRefresh = forceRefresh
        self.loadingView = loadingView
        self.errorView = errorView
    }

    private init(
        experimentKey: String,
        onCompleted: ((UpliftFunnelFlowResult) -> Void)?,
        userVariables: [String: JSONValue]?,
        forceRefresh: Bool,
        loadingView: (() -> AnyView)?,
        errorView: ((Error, @escaping () -> Void) -> AnyView)?
    ) {
        self.flowKey = experimentKey
        self.isExperiment = true
        self.onCompleted = onCompleted
        self.userVariables = userVariables
        self.forceRefresh = forceRefresh
        self.loadingView = loadingView
        self.errorView = errorView
    }

    /// Run an A/B experiment by its key. Identical loading/error/retry UX,
    /// but wired to `UpliftFunnel.startExperiment`: the SDK attaches the
    /// sticky subject id so the server buckets the user into a stable
    /// variant, and the resolved assignment is surfaced on
    /// `UpliftFunnelFlowResult.experiment`.
    ///
    /// Safe to leave in production after a decision: a stopped experiment
    /// serves the baseline and a rolled-out one serves the winning variant.
    public static func experiment(
        _ key: String,
        onCompleted: ((UpliftFunnelFlowResult) -> Void)? = nil,
        userVariables: [String: JSONValue]? = nil,
        forceRefresh: Bool = false,
        loadingView: (() -> AnyView)? = nil,
        errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil
    ) -> UpliftFunnelFlowView {
        UpliftFunnelFlowView(
            experimentKey: key, onCompleted: onCompleted,
            userVariables: userVariables, forceRefresh: forceRefresh,
            loadingView: loadingView, errorView: errorView)
    }

    private enum Phase {
        case loading
        case failed(Error)
        case ready(FlowSessionStart)
    }

    @State private var phase: Phase = .loading
    @State private var loadCount = 0

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingView?() ?? AnyView(
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
            case .failed(let error):
                errorView?(error, retry) ?? AnyView(DefaultErrorView(
                    error: error, retry: retry))
            case .ready(let start):
                UpliftFunnelSessionView(
                    session: start.session,
                    onCompleted: { variables, reason in
                        emit(start, reason: reason, variables: variables)
                    },
                    onAbandoned: { variables, reason in
                        emit(start, reason: reason, variables: variables)
                    })
            }
        }
        .task(id: loadCount) {
            guard case .loading = phase else { return }
            do {
                let start: FlowSessionStart
                if isExperiment {
                    start = try await UpliftFunnel.startExperiment(
                        flowKey, forceRefresh: forceRefresh,
                        userVariables: userVariables)
                } else {
                    start = try await UpliftFunnel.start(
                        flowKey, forceRefresh: forceRefresh,
                        userVariables: userVariables)
                }
                phase = .ready(start)
            } catch {
                phase = .failed(error)
            }
        }
    }

    private func retry() {
        phase = .loading
        loadCount += 1
    }

    private func emit(
        _ start: FlowSessionStart, reason: String, variables: [String: JSONValue]
    ) {
        onCompleted?(UpliftFunnelFlowResult(
            endReason: reason,
            variables: variables,
            source: start.source,
            experiment: start.experiment))
    }
}

struct DefaultErrorView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text(error.localizedDescription)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Retry")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
