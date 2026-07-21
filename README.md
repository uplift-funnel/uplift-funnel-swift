# UpliftFunnel iOS SDK

Native SwiftUI SDK for [Uplift Funnel](https://upliftfunnel.com) — render
server-authored onboarding funnels and paywalls as native iOS UI from a
single JSON contract. Full behavioral parity with `uplift_funnel_flutter`
(the reference SDK): same primitive-tree renderer, same flow engine, same
caching/ETag strategy, same analytics wire format.

- **JSON-to-native**: the API serves a server-expanded primitive tree
  (stack/text/image/button/choice/plan_picker/… — 31 node types); the SDK is
  a dumb interpreter. New archetypes reach installed apps with no update.
- **Forward-compatible**: unknown node types render a neutral placeholder,
  unknown props are ignored (see `docs/sdk-compatibility.md` in the platform
  repo).
- **Offline-first**: cache-first with background ETag revalidation; flows
  open instantly from cache and refresh for next launch.
- **Full-funnel analytics**: durable event queue (survives app kill),
  batched uploads with backoff, experiment tagging, purchase funnel events.
- Zero third-party dependencies. iOS 15+, Swift Package Manager.

## Install

```swift
// Package.swift
.package(path: "../funnel-ios"),  // or the git URL once published
// target dependency:
.product(name: "UpliftFunnel", package: "funnel-ios")
```

## Quickstart

```swift
import UpliftFunnel

// 1) At app startup
await UpliftFunnel.configure(apiKey: "fnl_pk_…", appVersion: "2.4.0")

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

Every purchase attempt/outcome is auto-tracked (`purchase_attempted`,
`purchase_succeeded`, `purchase_cancelled`, …) so paywall drop-off is
measurable server-side.

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
| SharedPreferences `funnel.*` keys | UserDefaults, same key names |

Storage keys, event wire shapes, cache format, and condition semantics are
byte-for-byte compatible with the Flutter SDK.

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

## Known v1 limitations (parity-tracked with Flutter 0.5.x)

- **Lottie** renders a static placeholder (Flutter does the same).
- **Custom fonts**: `font_family` aliases (`system`/`serif`/`mono`) map to
  system designs; any other family renders iff the host app bundles a font
  with that name. No runtime Google Fonts download yet.
- `justify: between/around` and proportional multi-`flex` are approximated
  with SwiftUI spacers; exotic layouts may differ slightly from the Flutter
  goldens.
- No snapshot tests yet — the Flutter goldens are the visual reference.
