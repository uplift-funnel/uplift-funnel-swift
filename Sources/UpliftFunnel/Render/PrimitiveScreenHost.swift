import Foundation
import SwiftUI
import UpliftLayout

// Bridges a live FlowSession to the v3 screen renderer. Turns session state
// (current screen id, variables) into the shape the renderer expects, and wires
// taps back into the session — plus the purchase-analytics bridge.

struct PrimitiveScreenHost: View {
    let screen: FunnelScreen
    @ObservedObject var session: FlowSession
    let primFlow: PrimFlow
    let theme: PrimTheme

    /// Back-chevron visibility captured by the session view at screen entry.
    /// Passed by value so an outgoing screen mid-transition keeps the state
    /// it was entered with (reading `session.canGoBack` live would flip the
    /// chevron on the old screen the instant history changes). Nil falls
    /// back to the live session value (standalone hosting, tests).
    var showBack: Bool?
    var onSignIn: ((String) async -> Bool)?
    var onPermission: ((String) async -> Bool)?
    var onPhotoUpload: ((PhotoUploadRequest) async -> String?)?
    /// Host billing handoff, wrapped here with plan → store-product
    /// resolution and purchase analytics before it reaches the renderer.
    var onPurchase: PurchaseHandler?
    var onRestore: (() async -> Bool)?
    var reduceMotion = false

    /// Store data for the `{{product.*}}` tokens, published by the host.
    var products: [String: [String: String]] = [:]

    @State private var images: [String: CGImage] = [:]

    var body: some View {
        GeometryReader { geo in
            // ONE answer, used for both the bar and the box below it. Reading
            // a constant here while the bar drew something else is what made
            // the body 24pt short on every screen with no back or close.
            let canGoBack = showBack ?? session.canGoBack
            // From the WINDOW, not from `geo`. This view says
            // `.ignoresSafeArea()` so a hero can bleed under the status bar,
            // and a proxy inside that reports zero — which padded the chrome by
            // nothing and put the close button in the status bar.
            let safeTop = max(SafeArea.top, Double(geo.safeAreaInsets.top))
            // The other end of the same problem, and the one nothing was
            // reading. `SafeArea.bottom` existed and was never called: the body
            // ran to the physical bottom of the display, so a footer pinned
            // "24pt from the bottom" landed inside the home-indicator band on
            // every notched device — while the dashboard preview, which does
            // reserve it, showed the author a footer sitting clear of it.
            let safeBottom = max(SafeArea.bottom, Double(geo.safeAreaInsets.bottom))
            let chrome = TopBarChrome.height(for: screenChrome(), canGoBack: canGoBack)
            VStack(spacing: 0) {
                TopBarChrome(
                    topBar: screenChrome(),
                    palette: theme.colors,
                    canGoBack: canGoBack,
                    onBack: { session.goBack() },
                    onClose: { session.handleAction("close", fromScreenId: screen.id) },
                    onSkip: { session.handleAction("next", fromScreenId: screen.id) }
                )
                // ABOVE the body, which now reaches up into this row: a screen
                // whose hero carries `ignoreSafeArea` draws behind the chrome,
                // and a back chevron a photo paints over is a control the user
                // cannot find. The stack alone would put the body on top, since
                // it comes second.
                .zIndex(1)
                PrimitiveScreenV3(
                    flow: primFlow.raw.flowDictionary,
                    screenIndex: session.flow.screens.firstIndex { $0.id == screen.id } ?? 0,
                    locale: resolveLocale(
                        locales: primFlow.locales, defaultLocale: primFlow.defaultLocale
                    ),
                    products: products,
                    size: CGSize(
                        width: geo.size.width,
                        height: ScreenBox.bodyHeight(
                            display: geo.size.height,
                            safeTop: safeTop,
                            safeBottom: safeBottom,
                            chrome: chrome
                        )
                    ),
                    // The WHOLE band above the body: the status bar and the
                    // chrome row. `ignoreSafeArea` means the top of the
                    // display, and lifting a hero by the status bar alone left
                    // it sitting a chrome row short of it — the same gap the
                    // dashboard had until `--uf-safe-top` started including it.
                    safeTop: safeTop + chrome,
                    // Paint-only: the body already excludes it.
                    safeBottom: safeBottom,
                    // Identity, not content: the flow dictionary cannot be
                    // hashed, and its id plus version moves exactly when the
                    // document does.
                    flowVersion: "\(session.flow.id)@\(primFlow.raw["version"].stringifiedValue ?? "0")",
                    answers: answers,
                    images: images,
                    onAction: dispatch,
                    onPhotoUpload: { source, shape in
                        await onPhotoUpload?(PhotoUploadRequest(source: source, shape: shape))
                    },
                    onPermission: { type in await onPermission?(type) ?? false },
                    onSignIn: { provider in await onSignIn?(provider) ?? true }
                )
            }
            .padding(.top, safeTop)
            .padding(.bottom, safeBottom)
        }
        .ignoresSafeArea()
        .task { await loadImages() }
    }

    /// Session variables as the renderer's flat strings, and back again.
    ///
    /// A Binding rather than a copy because the renderer OWNS the edit: a
    /// keystroke has to reach the session immediately or `enabled_when` gating
    /// and validation both lag a character behind.
    private var answers: Binding<[String: String]> {
        Binding(
            get: { stringifyVariables(session.variables) },
            set: { next in
                let current = stringifyVariables(session.variables)
                // Only what actually changed — writing every key on every
                // keystroke would emit a variable_set per key per character.
                for (key, value) in next where current[key] != value {
                    session.setVariableLocal(key, decodeValue(value))
                }
            }
        )
    }

    /// The screen's `top_bar`, straight from the document.
    private func screenChrome() -> [String: Any]? {
        let doc = primFlow.raw.flowDictionary
        let index = session.flow.screens.firstIndex { $0.id == screen.id } ?? 0
        guard let screens = doc["screens"] as? [[String: Any]],
              screens.indices.contains(index) else { return nil }
        return screens[index]["top_bar"] as? [String: Any]
    }

    // MARK: - actions

    private func dispatch(_ action: String) {
        switch action {
        case "purchase":
            Task { await purchase() }
        case "restore":
            Task { await restore() }
        default:
            if action.hasPrefix("permission:") {
                let type = String(action.dropFirst("permission:".count))
                Task {
                    _ = await onPermission?(type)
                    session.handleAction("next", fromScreenId: screen.id)
                }
                return
            }
            // Any pending keystrokes become one committed value before the
            // screen changes, which is what keeps a typed answer from being
            // recorded twice or not at all.
            session.flushPendingVariableSets()
            session.handleAction(action, fromScreenId: screen.id)
        }
    }

    private func purchase() async {
        guard let onPurchase else {
            session.handleAction("next", fromScreenId: screen.id)
            return
        }
        let planId = selectedProductRef()
        let ok = await performPurchaseBridge(
            session: session, screenId: screen.id,
            plan: planId.map { .string($0) }, planId: planId,
            handler: onPurchase
        )
        if ok { session.handleAction("next", fromScreenId: screen.id) }
    }

    private func restore() async {
        guard let onRestore else { return }
        if await onRestore() { session.handleAction("next", fromScreenId: screen.id) }
    }

    /// Which product the user is buying.
    ///
    /// v3 has no `plan_picker` node — a paywall is composed boxes, each bound
    /// to a product by `behavior.product.ref` and selected through a group. So
    /// the answer is: find the selected option, and read the product ref off
    /// the node that carries it. Falls back to the option marked `default`,
    /// because a single-plan paywall has no selection step and must still be
    /// buyable.
    private func selectedProductRef() -> String? {
        let doc = primFlow.raw.flowDictionary
        let index = session.flow.screens.firstIndex { $0.id == screen.id } ?? 0
        guard let screens = doc["screens"] as? [[String: Any]],
              screens.indices.contains(index),
              let root = screens[index]["root"] as? [String: Any] else { return nil }
        let answers = stringifyVariables(session.variables)
        // The group's own name is not necessarily where its answer lives, and a
        // multi group's answer is a JSON array — the same two rules the
        // `selected` state resolves by. Getting them wrong here is not a
        // cosmetic bug like a card that fails to highlight: this is the ref
        // that gets CHARGED, and the fallback it silently used instead is
        // whichever plan the author marked `default`.
        let groups = LayoutDecoder.interactions(flow: doc, screenIndex: index).groups

        var fallback: String?
        var found: String?
        func walk(_ node: [String: Any]) {
            let behavior = node["behavior"] as? [String: Any]
            if let ref = (behavior?["product"] as? [String: Any])?["ref"] as? String {
                if let s = behavior?["select"] as? [String: Any],
                   let group = s["group"] as? String, let value = s["value"] as? String {
                    let key = groups[group]?.saveTo ?? group
                    if answerHolds(answers[key], value) { found = found ?? ref }
                    if (s["default"] as? Bool) == true { fallback = fallback ?? ref }
                } else {
                    fallback = fallback ?? ref
                }
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(root)
        return found ?? fallback
    }

    /// Whether an answer holds `value`: a scalar equals it, and the canonical
    /// multi-select encoding (`["a","b"]`) contains it.
    private func answerHolds(_ answer: String?, _ value: String) -> Bool {
        guard let answer else { return false }
        guard answer.hasPrefix("[") else { return answer == value }
        return decodeList(answer).contains(value)
    }

    // MARK: - images

    /// Fetch every image the screen names, before it is drawn.
    ///
    /// The painter never blocks — a missing image draws its placeholder and the
    /// frame is still right — so this is a refinement rather than a gate, and a
    /// screen with a slow photo appears immediately with everything else in
    /// place.
    private func loadImages() async {
        let doc = primFlow.raw.flowDictionary
        let index = session.flow.screens.firstIndex { $0.id == screen.id } ?? 0
        // Resolved by the decoder, not re-walked here: a URL that interpolates
        // an answer has to be fetched under the string the paint will ask for.
        let answers = stringifyVariables(session.variables)
        let urls = LayoutDecoder.imageURLs(
            flow: doc,
            screenIndex: index,
            locale: resolveLocale(
                locales: primFlow.locales, defaultLocale: primFlow.defaultLocale
            ),
            input: LayoutInput(
                selections: answers, variables: answers, products: products
            )
        )

        // Fetched CONCURRENTLY and applied in ONE assignment.
        //
        // Both halves matter. Assigning per image meant N writes to `@State`,
        // and every write re-ran the view — so a screen with four photos laid
        // itself out four extra times, after it was already on screen and
        // already correct. That was the visible stutter on first appearance.
        // Serial fetches then made it N round-trips deep as well.
        //
        // The model cache is what makes the single assignment nearly free:
        // images are not part of its key, so this repaints without re-solving.
        let wanted = urls.filter { images[$0] == nil }
        guard !wanted.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, CGImage?).self) { group in
            for url in wanted {
                group.addTask {
                    guard let link = URL(string: url),
                          let (data, _) = try? await URLSession.shared.data(from: link),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { return (url, nil) }
                    return (url, image)
                }
            }
            var out: [String: CGImage] = [:]
            for await (url, image) in group {
                if let image { out[url] = image }
            }
            return out
        }
        guard !fetched.isEmpty else { return }
        images.merge(fetched) { _, new in new }
    }

    /// Device locale if the flow declares it, else the flow's default.
    private func resolveLocale(locales: [String], defaultLocale: String) -> String {
        if let deviceCode = DeviceContext.languageCode, locales.contains(deviceCode) {
            return deviceCode
        }
        return defaultLocale
    }
}

/// Bridges the renderer's `purchase` tap to the registered PurchaseHandler:
/// resolves the tapped plan to its platform store product id, tracks the
/// attempt + outcome, and gates advancing on `.purchased`.
@MainActor
func performPurchaseBridge(
    session: FlowSession, screenId: String, plan: JSONValue?, planId: String?,
    handler: PurchaseHandler
) async -> Bool {
    let productId = plan.flatMap { planProductId($0) }
    session.trackPurchase(stage: "attempted", planId: planId, productId: productId)

    let result = await handler(PurchaseRequest(
        flowId: session.flow.id,
        screenId: screenId,
        sessionId: session.sessionId,
        planId: planId,
        productId: productId,
        plan: plan))

    let stage: String
    switch result {
    case .purchased: stage = "succeeded"
    case .cancelled: stage = "cancelled"
    case .failed: stage = "failed"
    case .pending: stage = "pending"
    }
    session.trackPurchase(stage: stage, planId: planId, productId: productId)
    return result == .purchased
}

/// Session vars → renderer strings. Arrays (multi-select `array_string`
/// variables) stringify as a JSON array — the renderer's canonical
/// multi-select encoding — so membership round-trips; everything else is the
/// scalar's plain string form.
func stringifyVariables(_ variables: [String: JSONValue]) -> [String: String] {
    variables.mapValues { v in
        if v.arrayValue != nil { return v.serializedString() }
        return v.stringifiedValue ?? (v.isNull ? "" : v.serializedString())
    }
}

/// Inverse of `stringifyVariables` for values written by the renderer: a
/// JSON-array string decodes back to an array; anything else passes through
/// as the plain string.
func decodeValue(_ value: String) -> JSONValue {
    if value.hasPrefix("["),
       let decoded = try? JSONValue.parse(value),
       decoded.arrayValue != nil {
        return decoded
    }
    return .string(value)
}
