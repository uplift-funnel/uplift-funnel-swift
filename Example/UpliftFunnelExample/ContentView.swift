import SwiftUI
import UpliftFunnel

/// Stand-in for a real OS dialog / auth sheet / purchase sheet.
///
/// A handler `await`s `ask(_:)`, which suspends until the user taps a button —
/// so BOTH branches of a flow are walkable (deny a permission, cancel a
/// purchase) without wiring a real integration first. Mirrors the Flutter
/// example's `_confirm`.
@MainActor
final class DemoPrompt: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var message = ""
    @Published private(set) var confirmLabel = "Allow"
    /// Info-only prompts (the link handler) get a single OK button.
    @Published private(set) var isInfo = false

    private var continuation: CheckedContinuation<Bool, Never>?

    /// Suspends until the user answers. A second ask while one is still open
    /// resolves the first as denied rather than dropping its continuation.
    func ask(_ message: String, confirmLabel: String = "Allow") async -> Bool {
        resolve(false)
        self.message = message
        self.confirmLabel = confirmLabel
        isInfo = false
        isPresented = true
        return await withCheckedContinuation { self.continuation = $0 }
    }

    /// Fire-and-forget notice — the analog of the Flutter demo's snackbar.
    func info(_ message: String) {
        resolve(false)
        self.message = message
        isInfo = true
        isPresented = true
    }

    /// Idempotent: resuming twice would trap, so the continuation is cleared
    /// as it resolves.
    func resolve(_ granted: Bool) {
        isPresented = false
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

/// Demo host for the UpliftFunnel SDK against a local `pnpm dev:api`
/// (http://localhost:3000). Paste a dev public key (`fnl_pk_…` — printed to
/// /tmp/funnel-demo-keys by the API seeder), enter a flow key, hit Start.
struct ContentView: View {
    @StateObject private var prompt = DemoPrompt()

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
        Group {
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

        // ── Native handoffs ──────────────────────────────────────────────
        // The flow JSON declares WHAT happens (a signin gate, a permission
        // ask, a paywall CTA, a Terms link); these handlers are HOW your app
        // does it. Every one is optional, so you can wire them one at a time.
        //
        // This demo surfaces each as a confirm dialog rather than faking a
        // success, so the deny/cancel branches are reachable too. In a real
        // app you'd call the commented-out API instead.
        UpliftFunnel.registerSignInHandler { provider in
            // e.g. ASAuthorizationAppleIDProvider().createRequest() driven by
            // an ASAuthorizationController when provider == "apple".
            print("[example] sign in requested: \(provider)")
            return await prompt.ask("Sign in with \(provider)?")
        }
        UpliftFunnel.registerPermissionHandler { permission in
            // e.g. UNUserNotificationCenter.current()
            //        .requestAuthorization(options: [.alert, .badge, .sound])
            print("[example] permission requested: \(permission)")
            return await prompt.ask("Grant \(permission) permission?")
        }
        UpliftFunnel.registerPurchaseHandler { request in
            // e.g. Purchases.shared.purchase(product:) (RevenueCat) or
            // StoreKit's Product.purchase(). Map cancel/failure onto the
            // matching PurchaseResult so the user stays on the paywall and
            // analytics records the drop-off.
            print("[example] purchase requested: plan=\(request.planId ?? "-") "
                  + "product=\(request.productId ?? "-")")
            let bought = await prompt.ask(
                "Purchase \"\(request.productId ?? request.planId ?? "—")\" "
                + "(plan \(request.planId ?? "—"))?",
                confirmLabel: "Buy")
            return bought ? .purchased : .cancelled
        }
        UpliftFunnel.registerRestoreHandler {
            // e.g. Purchases.shared.restorePurchases() — return whether an
            // active entitlement actually came back.
            print("[example] restore requested")
            return await prompt.ask("Restore purchases?", confirmLabel: "Restore")
        }
        UpliftFunnel.registerPhotoUploadHandler { request in
            // e.g. PHPickerViewController honoring request.source, returning
            // the picked asset's local path. Nil = the user backed out.
            print("[example] photo requested: source=\(request.source) "
                  + "shape=\(request.shape)")
            let picked = await prompt.ask(
                "Pick a photo (source \(request.source), \(request.shape))?",
                confirmLabel: "Pick")
            return picked ? "demo://photo" : nil
        }
        UpliftFunnel.registerLinkHandler { url in
            // e.g. UIApplication.shared.open(parsed). The demo only reports
            // it, so tapping Terms mid-flow doesn't kick you out of the app.
            print("[example] open link: \(url)")
            prompt.info("Would open \(url)")
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
