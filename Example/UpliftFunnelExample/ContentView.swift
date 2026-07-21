import SwiftUI
import UpliftFunnel

/// Demo host for the UpliftFunnel SDK against a local `pnpm dev:api`
/// (http://localhost:3000). Paste a dev public key (`fnl_pk_…` — printed to
/// /tmp/funnel-demo-keys by the API seeder), enter a flow key, hit Start.
struct ContentView: View {
    @AppStorage("demo.apiKey") private var apiKey = ""
    @AppStorage("demo.serverUrl") private var serverUrl = "http://localhost:3000"
    @AppStorage("demo.flowKey") private var flowKey = "cal-ai-clone"

    @State private var isExperiment = false
    @State private var forceRefresh = false
    @State private var configured = false
    @State private var presentingFlow = false
    @State private var lastResult: String = "—"

    var body: some View {
        NavigationView {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("API key (fnl_pk_…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Flow") {
                    TextField("Flow key", text: $flowKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Experiment", isOn: $isExperiment)
                    Toggle("Force refresh", isOn: $forceRefresh)
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
            }
            .navigationTitle("Uplift Funnel")
        }
        .fullScreenCover(isPresented: $presentingFlow) {
            flowView
        }
        .task {
            // CLI/E2E hook: `simctl launch ... -demo.autostart YES
            // -demo.apiKey fnl_pk_… -demo.flowKey cal-ai-clone` — the
            // -demo.* arguments land in the UserDefaults argument domain,
            // overriding @AppStorage, and autostart opens the flow directly.
            if UserDefaults.standard.bool(forKey: "demo.autostart"),
               !apiKey.isEmpty, !flowKey.isEmpty {
                await configureSDK()
                presentingFlow = true
            }
        }
    }

    @ViewBuilder
    private var flowView: some View {
        if isExperiment {
            UpliftFunnelFlowView.experiment(
                flowKey,
                onCompleted: handleResult,
                forceRefresh: forceRefresh)
        } else {
            UpliftFunnelFlowView(
                flowKey: flowKey,
                onCompleted: handleResult,
                forceRefresh: forceRefresh)
        }
    }

    private func handleResult(_ result: UpliftFunnelFlowResult) {
        lastResult = "\(result.endReason) · \(result.source.rawValue)\n"
            + result.variables
                .map { "\($0.key)=\($0.value.stringifiedValue ?? $0.value.serializedString())" }
                .sorted()
                .joined(separator: "\n")
        presentingFlow = false
    }

    private func configureSDK() async {
        await UpliftFunnel.configure(
            apiKey: apiKey,
            serverUrl: serverUrl,
            appVersion: "1.0.0-example")
        guard !configured else { return }
        configured = true

        // Demo handlers: log to console and succeed, so signin/permission/
        // purchase screens are walkable without real integrations.
        UpliftFunnel.registerLinkHandler { url in
            print("[example] open link: \(url)")
            if let parsed = URL(string: url) {
                UIApplication.shared.open(parsed)
            }
        }
        UpliftFunnel.registerSignInHandler { provider in
            print("[example] sign in via \(provider)")
            return true
        }
        UpliftFunnel.registerPermissionHandler { permission in
            print("[example] permission requested: \(permission)")
            return true
        }
        UpliftFunnel.registerRestoreHandler {
            print("[example] restore purchases")
            return false
        }
        UpliftFunnel.registerPurchaseHandler { request in
            print("[example] purchase plan=\(request.planId ?? "-") "
                  + "product=\(request.productId ?? "-")")
            return .purchased
        }
        // Fake catalog so {{price.X}} interpolation and plan_picker
        // auto-binding light up.
        UpliftFunnel.setProducts([
            UpliftFunnelProduct(
                id: "yearly_pro", price: "₺899,99", priceAmount: 899.99,
                period: .year, trialDays: 7, trialEligible: true),
            UpliftFunnelProduct(
                id: "monthly_pro", price: "₺149,99", priceAmount: 149.99,
                period: .month),
        ])
    }
}
