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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The same reason `DefaultErrorView` paints one: a
                        // transparent fallback inherits whatever is behind it,
                        // and a dark spinner on a dark host is as invisible as
                        // dark text was.
                        .background(SDKSurface.background))
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
                // The console half of the fix. The view below says what went
                // wrong, but only once somebody is looking at the device — and
                // a host that passes its own `errorView:` may render something
                // that says nothing at all. This line is what makes a failed
                // start greppable in Xcode either way.
                UpliftLog.error(
                    "\(isExperiment ? "startExperiment" : "start")"
                    + "(\"\(flowKey)\") failed: \(error.localizedDescription)")
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

/// The system background, for the two fallback states that have to be legible
/// on a host we know nothing about.
///
/// Both default states used to be transparent, which is what made the error
/// view unreadable in the field: over a host whose window is black, with a
/// colour scheme that resolves `.primary` to black, the message rendered
/// black on black. It occupied its three lines and said nothing. Painting the
/// system background means the foreground and the background always resolve
/// from the *same* colour scheme, so the pair can never disagree.
enum SDKSurface {
    static var background: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.white
        #endif
    }
}

/// Shown when a flow cannot be loaded and the host passed no `errorView:`.
///
/// ── What it says depends on the build ───────────────────────────────────────
///
/// DEBUG names the cause in the developer's terms — "Flow 'x' is not published
/// (404)" is the whole answer, and the point of this screen is that somebody
/// integrating the SDK reads it and knows what to change.
///
/// Release says none of that. A default this view supplies is, by definition,
/// one the host did not customise, so in a shipped app it is an *end user*
/// reading it — and "Check the apiKey passed to UpliftFunnel.configure" is
/// both meaningless and an internal detail. They get a neutral sentence and
/// the same Retry button. A host that wants better in production passes
/// `errorView:`.
struct DefaultErrorView: View {
    let error: Error
    let retry: () -> Void

    private var fetchError: FlowFetchError? { error as? FlowFetchError }

    /// One line naming the failure, in the reader's terms rather than HTTP's.
    ///
    /// Internal rather than private so `DefaultErrorCopyTests` can hold the
    /// switch to every `FlowFetchError.Kind`. The wording is the whole point
    /// of this view; a kind added later that silently fell through to
    /// "Something went wrong" would put the view back where it started.
    var headline: String {
        guard let kind = fetchError?.kind else { return "Something went wrong" }
        switch kind {
        case .notFound: return "This flow is not published"
        case .unauthorized: return "The API key was rejected"
        case .forbidden: return "This API key can't open that flow"
        case .network: return "Couldn't reach the server"
        case .invalidPayload: return "The flow couldn't be read"
        case .server: return "The server had a problem"
        }
    }

    var detail: String {
        #if DEBUG
        // `errorDescription` already carries the actionable sentence and the
        // status code; there is nothing to add and rewording it here would
        // give the same failure two different texts to search for.
        return error.localizedDescription
        #else
        return "Please try again."
        #endif
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text(headline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
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
        .background(SDKSurface.background)
    }
}
