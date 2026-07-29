# UpliftFunnel iOS SDK

Native SwiftUI SDK for [Uplift Funnel](https://upliftfunnel.com). Build an
onboarding flow or paywall in the dashboard, show it with one view, and change
it later without shipping an app update.

- **Native UI** — real SwiftUI, no WebView.
- **Opens instantly, works offline** — a flow the user has seen before renders
  from cache and refreshes in the background for next launch.
- **Survives new flows** — a flow using something this SDK version doesn't know
  degrades gracefully instead of breaking the screen.
- **Analytics and A/B built in** — nothing is lost if the app is killed or the
  device is offline.
- No third-party dependencies. iOS 15+, Swift Package Manager.

## Install

```swift
// Package.swift
.package(url: "https://github.com/uplift-funnel/uplift-funnel-swift.git", from: "0.7.1"),
// target dependency:
.product(name: "UpliftFunnel", package: "uplift-funnel-swift")
```

In Xcode: **File → Add Package Dependencies…**, paste the URL above, and pick
the `UpliftFunnel` library.

## Quickstart

```swift
import UpliftFunnel

// 1) At app startup
await UpliftFunnel.configure(apiKey: "fnl_pk_…", appVersion: "2.4.0")

// Pointing at a local API during development — debug builds only; setting
// this in a release build traps, because a shipped app talks to production.
// UpliftFunnel.debugServerUrl = "http://localhost:3000"

// 2) Drop a funnel into your view tree
UpliftFunnelFlowView(flowKey: "main-onboarding") { result in
    print(result.endReason)   // "completed" / "abandoned" / "skipped"
    print(result.variables)   // everything the user answered
}
```

Lower-level control (pre-started session, custom loading UI):

```swift
let start = try await UpliftFunnel.start("main-onboarding")
UpliftFunnelSessionView(session: start.session, onCompleted: { vars, reason in … })
```

### A/B experiments

```swift
UpliftFunnelFlowView.experiment("paywall-copy-test") { result in
    analytics.log("done", variant: result.experiment?.variantId)
}
```

Safe to leave in production after a decision: a stopped experiment serves
the baseline, a rolled-out one serves the winner. Bucketing is sticky per
subject (identified user id, else the per-install anonymous id).

### Handlers (native handoffs)

The SDK never talks to StoreKit, auth providers, or OS permission APIs
itself — it hands off to closures you register once after `configure`:

```swift
UpliftFunnel.registerPurchaseHandler { request in
    // request.productId is already resolved for iOS (product_id_ios wins)
    let result = try? await Purchases.shared.purchase(productId: request.productId!)
    return .purchased  // only .purchased advances the flow
}
UpliftFunnel.registerRestoreHandler { /* true only if something restored */ false }
UpliftFunnel.registerSignInHandler { provider in /* run Sign in with Apple… */ true }
UpliftFunnel.registerPermissionHandler { permission in /* real OS prompt */ true }
UpliftFunnel.registerPhotoUploadHandler { request in /* run your picker */ nil }
UpliftFunnel.registerLinkHandler { url in UIApplication.shared.open(URL(string: url)!) }
```

A `url:` href is authored content that arrives over the network, so the SDK
only forwards `https`, `http`, `mailto`, `tel` and `sms` to your handler —
everything else is dropped before it runs. To drive your own deep links from a
flow, opt the scheme in:

```swift
UpliftFunnel.registerLinkHandler(
    open, allowedSchemes: UpliftFunnel.defaultAllowedLinkSchemes.union(["myapp"]))
```

Every purchase attempt/outcome is auto-tracked (`purchase_attempted`,
`purchase_succeeded`, `purchase_cancelled`, …) so paywall drop-off is
measurable server-side.

### Consent and what leaves the device

**Your code always gets every answer** — the completion callback hands you the
full variable map, because it's your user's data. What follows is only about
what reaches the Uplift API.

Mark a variable **Private** in the dashboard and the SDK reports it as
answered, never as its content. Use it for anything that identifies a person or
describes their body — name, email, phone, birth date, weight. Leave it off for
the bounded answers segmentation runs on (choice, rating, scale, toggle), which
keep their values. The server derives the flag from the input that writes each
variable, so existing flows arrive classified.

```swift
await UpliftFunnel.configure(
    apiKey: "fnl_pk_…",
    // Start with analytics off and turn it on when the user consents.
    trackingEnabled: false,
    // Redact these too, whatever the flow says.
    redactVariables: ["referral_note"])

UpliftFunnel.setTrackingEnabled(true) // consent granted
```

Turning tracking off drops whatever is already queued rather than holding it
for later. Flows still fetch and render while it's off — gating that on consent
would leave you with a blank screen instead of an onboarding.

### Product catalog (paywall display)

```swift
UpliftFunnel.setProducts([
    UpliftFunnelProduct(id: "yearly_pro", price: "₺899,99",
                        priceAmount: 899.99, period: .year, trialDays: 7),
])
```

Each product fans out into `{{price.yearly_pro}}`,
`{{price_per_month.yearly_pro}}`, `{{trial_days.yearly_pro}}`, … variables,
and `plan_picker` cards auto-bind their price display via the plan's
`product_id` / `product_id_ios`.

### Identity & analytics

```swift
try await UpliftFunnel.identify(userId: appUserId)   // = RevenueCat app_user_id
try await UpliftFunnel.resetIdentity()               // logout: new anonymous id
try await UpliftFunnel.setAttribution(["source": "meta", "campaign": "…"])
try await UpliftFunnel.track("first_workout_completed")
```

## Flutter ↔ iOS API mapping

| Flutter (`uplift_funnel_flutter`) | iOS (`UpliftFunnel`) |
|---|---|
| `UpliftFunnel.configure(...)` | `UpliftFunnel.configure(...)` (same) |
| `UpliftFunnelFlow(flowKey)` widget | `UpliftFunnelFlowView(flowKey:)` |
| `UpliftFunnelFlow.experiment(key)` | `UpliftFunnelFlowView.experiment(key)` |
| `UpliftFunnelFlowView(session:)` | `UpliftFunnelSessionView(session:)` |
| `UpliftFunnelFlowResult` | `UpliftFunnelFlowResult` (same fields) |
| `Flow` / `Condition` / `Transition` | `FunnelFlow` / `FunnelCondition` / `FunnelTransition` |

The two SDKs behave identically, so a flow you build once behaves the same on
both — useful if you ship a Flutter app and a native iOS app against the same
dashboard.

## Example app

`Example/UpliftFunnelExample.xcodeproj` — a form to paste a dev key + flow
key, then presents the flow full-screen. Against a local platform:

```bash
cd ~/Documents/funnel-platform
pnpm dev:api                    # Hono API on :3000
cd apps/api && pnpm seed        # prints a fnl_pk_… dev key, seeds cal-ai-clone
```

Simulator reaches the host's `http://localhost:3000` directly
(`NSAllowsLocalNetworking` is set in the example's Info.plist).

CLI/E2E launch without touching the UI:

```bash
xcrun simctl launch booted com.upliftfunnel.example \
  -demo.autostart YES -demo.apiKey fnl_pk_… \
  -demo.serverUrl http://localhost:3000 -demo.flowKey cal-ai-clone
```

## Tests

```bash
swift test   # runs from the CLI on macOS — no simulator needed
```

The suite is a port of the Flutter SDK's behavioral tests (engine,
conditions, fetcher/ETag, event uploader, identity, choice multi-select,
enabled_when, plan parsing, purchase funnel, pinned-CTA extraction).
Fixtures under `Tests/UpliftFunnelTests/Fixtures/` are copied from the
Flutter SDK's `test/fixtures/` — re-sync when the schema package changes.

## Known limitations

- **Lottie** renders a static placeholder.
- **Custom fonts**: `font_family` aliases (`system`/`serif`/`mono`) map to
  system designs; any other family renders iff the host app bundles a font
  with that name. No runtime Google Fonts download yet.
- Unusual layout combinations may render slightly differently from the Flutter
  SDK; the common cases match.
