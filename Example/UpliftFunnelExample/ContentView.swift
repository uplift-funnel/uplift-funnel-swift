import SwiftUI
import UpliftFunnel

/// Demo host for the UpliftFunnel SDK.
///
/// It exists to show the seam between a flow and the app around it: every host
/// handoff the engine can ask for, the store catalog a paywall reads its prices
/// from, the identity and analytics calls, and an A/B run.
///
/// Paste a public key (`fnl_pk_…` from **SDK & API** in the dashboard), enter a
/// flow key, hit Start. Requests go to the production API unless the build was
/// launched with a `UPLIFT_SERVER_URL` — see `DemoServer`.
struct ContentView: View {
    @StateObject private var prompt = DemoPrompt()

    @AppStorage("demo.apiKey") private var apiKey = ""
    @AppStorage("demo.flowKey") private var flowKey = ""

    @State private var isExperiment = false
    @State private var forceRefresh = false
    @State private var trackingEnabled = true
    @State private var configured = false
    @State private var presentingFlow = false
    @State private var lastResult = "—"

    var body: some View {
        NavigationView {
            Form {
                Section("Flow") {
                    TextField("Public key (fnl_pk_…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Flow key", text: $flowKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Run as an A/B experiment", isOn: $isExperiment)
                    Toggle("Force refresh", isOn: $forceRefresh)
                    // The single-parameter closure, not the iOS 17 two-value
                    // one: this target deploys to iOS 16.
                    Toggle("Analytics", isOn: $trackingEnabled)
                        .onChange(of: trackingEnabled) { enabled in
                            guard configured else { return }
                            UpliftFunnel.setTrackingEnabled(enabled)
                            prompt.note("tracking \(enabled ? "enabled" : "disabled")")
                        }
                }
                Section {
                    Button("Start flow") {
                        Task {
                            await configureSDK()
                            presentingFlow = true
                        }
                    }
                    .disabled(apiKey.isEmpty || flowKey.isEmpty)
                }
                Section("Last result") {
                    Text(lastResult).font(.footnote.monospaced())
                    if let experiment = UpliftFunnel.lastExperiment {
                        Text("experiment: \(experiment.experimentId):"
                             + "\(experiment.variantId)"
                             + (experiment.variantName.map { " (\($0))" } ?? ""))
                            .font(.footnote.monospaced())
                    }
                }
                identitySection
                Section("Handoff log") {
                    if prompt.log.isEmpty {
                        Text("Nothing yet. Start a flow and tap through it — "
                             + "every handoff the engine asks for shows up here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(prompt.log, id: \.self) { line in
                            Text(line).font(.footnote.monospaced())
                        }
                        Button("Clear", role: .destructive) { prompt.clearLog() }
                    }
                }
            }
            .navigationTitle("Uplift Funnel")
        }
        .fullScreenCover(isPresented: $presentingFlow) {
            flowView
        }
        .task {
            // CLI/E2E hook: `simctl launch ... -demo.autostart YES
            // -demo.apiKey fnl_pk_… -demo.flowKey cal-ai-clone` — the -demo.*
            // arguments land in the UserDefaults argument domain, overriding
            // @AppStorage, and autostart opens the flow directly.
            if UserDefaults.standard.bool(forKey: "demo.autostart"),
               !apiKey.isEmpty, !flowKey.isEmpty {
                await configureSDK()
                presentingFlow = true
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section("Identity & analytics") {
            Button("Identify") {
                Task {
                    await configureSDK()
                    try? await UpliftFunnel.identify(
                        userId: "demo-user-1",
                        attributes: ["plan": .string("free"),
                                     "signup_source": .string("demo")])
                    prompt.note("identify · demo-user-1")
                }
            }
            Button("Reset identity") {
                Task {
                    await configureSDK()
                    try? await UpliftFunnel.resetIdentity()
                    prompt.note("reset identity")
                }
            }
            Button("Track event") {
                Task {
                    await configureSDK()
                    try? await UpliftFunnel.track(
                        "demo_button_tapped",
                        properties: ["where": .string("content_view")])
                    prompt.note("track · demo_button_tapped")
                }
            }
            Button("Set attribution") {
                Task {
                    await configureSDK()
                    try? await UpliftFunnel.setAttribution(
                        ["network": "demo", "campaign": "readme"])
                    prompt.note("attribution set")
                }
            }
            Button("Flush events") {
                Task {
                    await configureSDK()
                    await UpliftFunnel.flushEvents()
                    prompt.note("events flushed")
                }
            }
        }
    }

    @ViewBuilder
    private var flowView: some View {
        Group {
            if isExperiment {
                UpliftFunnelFlowView.experiment(
                    flowKey,
                    onCompleted: handleResult,
                    userVariables: demoUserVariables,
                    forceRefresh: forceRefresh,
                    loadingView: { AnyView(DemoLoadingView()) },
                    errorView: { error, retry in
                        AnyView(DemoErrorView(error: error, retry: retry))
                    })
            } else {
                UpliftFunnelFlowView(
                    flowKey: flowKey,
                    onCompleted: handleResult,
                    userVariables: demoUserVariables,
                    forceRefresh: forceRefresh,
                    loadingView: { AnyView(DemoLoadingView()) },
                    errorView: { error, retry in
                        AnyView(DemoErrorView(error: error, retry: retry))
                    })
            }
        }
        // Handlers only ever fire while a flow is on screen, so the alert
        // lives on the cover's content — an alert attached to the form
        // underneath would never present.
        .alert("Demo handler", isPresented: $prompt.isPresented) {
            if prompt.isInfo {
                Button("OK") { prompt.resolve(false) }
            } else {
                Button("Don't Allow", role: .cancel) { prompt.resolve(false) }
                Button(prompt.confirmLabel) { prompt.resolve(true) }
            }
        } message: {
            Text(prompt.message)
        }
    }

    /// Anything the app already knows. Available to the flow as `{{source}}` /
    /// `{{tier}}` and to its transition conditions.
    private var demoUserVariables: [String: JSONValue] {
        ["source": .string("demo"), "tier": .string("free")]
    }

    private func handleResult(_ result: UpliftFunnelFlowResult) {
        lastResult = "\(result.endReason) · \(result.source.rawValue)\n"
            + result.variables
                .map { "\($0.key)=\($0.value.stringifiedValue ?? $0.value.serializedString())" }
                .sorted()
                .joined(separator: "\n")
        prompt.note("flow ended · \(result.endReason)")
        presentingFlow = false
    }

    /// Configure once, then register the catalog and the handoffs.
    ///
    /// Order matters: `configure` starts the engine, and everything registered
    /// afterwards is what a flow is allowed to ask the app for.
    private func configureSDK() async {
        guard !configured else { return }
        // Debug-only hook, and it has to be set before configure reads it.
        UpliftFunnel.debugServerUrl = DemoServer.url
        await UpliftFunnel.configure(
            apiKey: apiKey,
            appVersion: "1.0.0-example",
            trackingEnabled: trackingEnabled,
            // Answers named here never leave the device in an event payload.
            redactVariables: ["email"])
        configured = true
        registerDemoHandoffs(prompt: prompt)
        prompt.note("configured · \(DemoServer.url ?? "production")")
    }
}

/// A host-supplied loading state, replacing the SDK's default spinner.
private struct DemoLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Fetching the flow…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A host-supplied error state. `retry` re-runs the fetch; without it the user
/// is stuck on whatever went wrong.
private struct DemoErrorView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Could not load the flow").font(.headline)
            Text(error.localizedDescription)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
