# FunnelOnboarding (iOS)

> SwiftPM-distributed iOS SDK for the Funnel onboarding platform — port of the Flutter SDK to native SwiftUI.

## Status

Sprint 7 skeleton. Implements:
- Models + Codable for the full Flow + Screen + Transition + Theme graph (18 archetypes parseable; 4 rendered)
- Pure-Swift `FlowEngine` state machine with the same operators and semantics as the Dart engine
- `@Observable` `FlowSession` exposing the current screen + an `AsyncStream<FlowEvent>`
- 4 archetype views (welcome, single_choice, scale, finale) and an `unsupported` fallback for the remaining 14 (will land in 7.1+)
- Default theme + token resolution (hex strings → SwiftUI `Color`)

Out of scope for this skeleton (will land in subsequent sprints):
- Cache + ETag-aware fetcher (mirrors the Dart `FlowFetcher`)
- HTTP event upload (mirrors `EventUploader`)
- Remaining 14 archetype views
- iOS demo app

## Quickstart (in your app's Package.swift)

```swift
.package(url: "https://github.com/funnel-oaas/funnel-ios", from: "0.1.0"),
```

```swift
import FunnelOnboarding
import SwiftUI

struct MyApp: App {
    @State private var session: FlowSession? = nil

    var body: some Scene {
        WindowGroup {
            if let session {
                FunnelOnboardingView(session: session) { vars, reason in
                    print("Done: \(reason) → \(vars)")
                }
            } else {
                ProgressView().task {
                    let json = try! String(contentsOf: Bundle.main.url(forResource: "flow", withExtension: "json")!)
                    let flow = try! Flow.decode(fromJSONString: json)
                    session = try! FlowSession(flow: flow)
                }
            }
        }
    }
}
```

## License

Apache 2.0.
