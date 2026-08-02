import Foundation
import UpliftFunnel

/// Where a non-production build points.
///
/// Not a field on screen and not a default in the source. A released build
/// talks to the production API and has no way to say otherwise —
/// `UpliftFunnel.debugServerUrl` traps in release for exactly that reason.
///
/// Two ways in, both outside the app's UI:
///   - the `UPLIFT_SERVER_URL` environment variable on the run scheme
///   - `-demo.serverUrl <url>` as a launch argument, for `simctl launch`
enum DemoServer {
    static var url: String? {
        if let fromEnvironment = ProcessInfo.processInfo
            .environment["UPLIFT_SERVER_URL"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        let fromArguments = UserDefaults.standard.string(forKey: "demo.serverUrl")
        return (fromArguments?.isEmpty == false) ? fromArguments : nil
    }
}

/// The store catalog a paywall reads its prices from.
///
/// Without it a paywall still renders — with the prices someone typed into the
/// dashboard, which are a preview and an offline fallback, not what the store
/// will charge. With it, every `{{product.*}}` token on a plan card resolves to
/// store truth.
///
/// `savings` is the one field only you can write: it is a phrase, in your
/// user's language. Left out, the engine derives an English "Save NN%" from
/// `originalPrice` and `priceAmount`.
enum DemoProducts {
    static let all: [UpliftFunnelProduct] = [
        UpliftFunnelProduct(
            id: "weekly_pro", price: "$6.99", priceAmount: 6.99,
            currencyCode: "USD", period: .week,
            trialDays: 3, trialEligible: true),
        UpliftFunnelProduct(
            id: "monthly_pro", price: "$12.99", priceAmount: 12.99,
            currencyCode: "USD", period: .month),
        UpliftFunnelProduct(
            id: "yearly_pro", price: "$59.99", priceAmount: 59.99,
            currencyCode: "USD", period: .year,
            trialDays: 7, trialEligible: true,
            originalPrice: "$155.88", pricePerMonth: "$5.00",
            savings: "Save 61%"),
    ]
}

/// Every host handoff, wired.
///
/// The flow JSON declares WHAT happens (a signin gate, a permission ask, a
/// paywall CTA, a Terms link); these are HOW your app does it. Each is
/// optional, so you can wire them one at a time — but each also has a defined
/// no-handler behaviour, and one of them will bite you: without a purchase
/// handler the SDK lets a `purchase` button simply *advance*.
///
/// The demo surfaces each as a confirm dialog rather than faking a success, so
/// the deny/cancel branches are reachable too. In a real app you would call the
/// commented-out API instead.
@MainActor
func registerDemoHandoffs(prompt: DemoPrompt) {
    UpliftFunnel.setProducts(DemoProducts.all)

    UpliftFunnel.registerSignInHandler { provider in
        // e.g. ASAuthorizationAppleIDProvider().createRequest() driven by an
        // ASAuthorizationController when provider == "apple".
        prompt.note("sign in · \(provider)")
        let ok = await prompt.ask("Sign in with \(provider)?")
        prompt.note("sign in → \(ok ? "signed in" : "declined")")
        return ok
    }

    UpliftFunnel.registerPermissionHandler { permission in
        // e.g. UNUserNotificationCenter.current()
        //        .requestAuthorization(options: [.alert, .badge, .sound])
        prompt.note("permission · \(permission)")
        let granted = await prompt.ask("Grant \(permission) permission?")
        prompt.note("permission → \(granted ? "granted" : "denied")")
        return granted
    }

    UpliftFunnel.registerPurchaseHandler { request in
        // e.g. Purchases.shared.purchase(product:) (RevenueCat) or StoreKit's
        // Product.purchase(). Map cancel/failure onto the matching
        // PurchaseResult so the user stays on the paywall and analytics
        // records the drop-off.
        prompt.note("purchase · plan=\(request.planId ?? "—") "
                    + "· product=\(request.productId ?? "—")")
        let bought = await prompt.ask(
            "Purchase \"\(request.productId ?? request.planId ?? "—")\" "
            + "(plan \(request.planId ?? "—"))?",
            confirmLabel: "Buy")
        prompt.note("purchase → \(bought ? "purchased" : "cancelled")")
        return bought ? .purchased : .cancelled
    }

    UpliftFunnel.registerRestoreHandler {
        // e.g. Purchases.shared.restorePurchases() — return whether an active
        // entitlement actually came back. App Store review expects a working
        // restore on any screen that sells a subscription.
        prompt.note("restore requested")
        let restored = await prompt.ask("Restore purchases?",
                                        confirmLabel: "Restore")
        prompt.note("restore → \(restored ? "restored" : "nothing to restore")")
        return restored
    }

    UpliftFunnel.registerPhotoUploadHandler { request in
        // e.g. PHPickerViewController honoring request.source, returning the
        // picked asset's local path. Nil = the user backed out.
        prompt.note("photo · source=\(request.source) · shape=\(request.shape)")
        let picked = await prompt.ask(
            "Pick a photo (source \(request.source), \(request.shape))?",
            confirmLabel: "Pick")
        prompt.note("photo → \(picked ? "returned" : "cancelled")")
        return picked ? "demo://photo" : nil
    }

    // Adding to the default set rather than replacing it: naming your own
    // schemes is how you opt a deep link in, not how you opt https out.
    UpliftFunnel.registerLinkHandler(
        { url in
            // e.g. UIApplication.shared.open(parsed). The demo only reports it,
            // so tapping Terms mid-flow doesn't kick you out of the app.
            prompt.note("link · \(url)")
            prompt.info("Would open \(url)")
        },
        allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes
            .union(["upliftdemo"]))
}
