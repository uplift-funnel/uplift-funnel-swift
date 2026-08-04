import Foundation
import SwiftUI

// The place the host makes for us.
//
// `inline_card` and `banner` are drawn here and nowhere else. The SDK never
// inserts a view into the app's hierarchy on its own — that is the line between
// this and an overlay tool, and it is a product decision rather than a
// technical one (spec 05 §Sunum, spec 15 non-goals). If the host never places a
// slot, a trigger that wanted one is reported unpresentable and the delivery
// log says so.

/// A slot a triggered flow may be drawn into.
///
/// ```swift
/// VStack {
///     UpliftFunnelSlot(slotId: "home_top")
///         .frame(height: 120)
///     …the rest of your screen
/// }
/// ```
///
/// Renders nothing until the server decides something for this slot id, so it
/// is safe to leave in place permanently. **Size it yourself**: the flow is
/// laid out into whatever box this view is given, and a document authored as a
/// banner in a 600-point box will look like a full screen in a banner's place.
public struct UpliftFunnelSlot: View {
    let slotId: String
    let onCompleted: ((UpliftFunnelFlowResult) -> Void)?

    public init(
        slotId: String,
        onCompleted: ((UpliftFunnelFlowResult) -> Void)? = nil
    ) {
        self.slotId = slotId
        self.onCompleted = onCompleted
    }

    @State private var decision: UpliftTriggerDecision?

    public var body: some View {
        Group {
            if let decision {
                UpliftFunnelFlowView(
                    flowKey: decision.flowSlug,
                    onCompleted: { result in
                        // Clear first: the flow is over, and a slot still
                        // holding it would keep a finished screen on the page.
                        self.decision = nil
                        onCompleted?(result)
                    },
                    // A slot is a small box on somebody else's screen. A
                    // spinner and an error panel there are worse than nothing,
                    // because the host budgeted the space for content and gets
                    // our chrome instead.
                    loadingView: { AnyView(EmptyView()) },
                    errorView: { _, _ in AnyView(EmptyView()) })
            } else {
                // Zero-size rather than a placeholder: a slot with nothing
                // decided must not push the host's own layout around.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear { UpliftFunnel.attachSlot(slotId) { self.decision = $0 } }
        .onDisappear { UpliftFunnel.detachSlot(slotId) }
    }
}
