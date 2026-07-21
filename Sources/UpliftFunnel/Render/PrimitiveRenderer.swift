import Foundation
import SwiftUI

// Primitive-tree renderer entry point (Spec v2 §4 layout engine + §9 render
// contract), ported from the Flutter SDK's `primitive_renderer.dart`. This
// is the SDK's only render path — the server serves a primitive tree for
// every screen. Unknown node types render a neutral placeholder; unknown
// props ride along ignored (forward compatibility).

@MainActor
func renderNode(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    switch n.type {
    // §3.1 layout
    case "stack": return renderStack(n, ctx)
    case "grid": return renderGrid(n, ctx)
    case "scroll": return renderScrollNode(n, ctx)
    case "spacer": return renderSpacer(n, ctx)
    // §3.2 content
    case "text": return renderText(n, ctx)
    case "rich_text": return renderRichText(n, ctx)
    case "image": return renderImage(n, ctx)
    case "icon": return renderIconNode(n, ctx)
    case "video": return renderMedia(n, ctx, kind: "video")
    case "lottie": return renderMedia(n, ctx, kind: "lottie")
    case "divider": return renderDivider(n, ctx)
    // §3.3 interactive / smart
    case "button": return renderButton(n, ctx)
    case "choice": return renderChoice(n, ctx)
    case "text_field": return renderTextField(n, ctx)
    case "number_field": return renderNumberField(n, ctx)
    case "slider": return renderSliderNode(n, ctx)
    case "scale": return renderScale(n, ctx)
    case "date_field": return renderDateField(n, ctx)
    case "toggle": return renderToggle(n, ctx)
    case "photo_upload": return renderPhotoUpload(n, ctx)
    // §3.4 composite
    case "carousel": return renderCarousel(n, ctx)
    case "swipe": return renderSwipe(n, ctx)
    case "progress": return renderProgress(n, ctx)
    case "rating": return renderRating(n, ctx)
    case "countdown": return renderCountdown(n, ctx)
    case "testimonial": return renderTestimonial(n, ctx)
    case "timeline": return renderTimeline(n, ctx)
    // §3.5 behavioral / native
    case "permission": return renderPermission(n, ctx)
    case "signin": return renderSignIn(n, ctx)
    case "paywall_handoff": return renderPaywallHandoff(n, ctx)
    case "plan_picker": return renderPlanPicker(n, ctx)
    case "custom": return renderCustom(n, ctx)
    default: return renderUnknown(n)
    }
}

// MARK: - Shared bits

/// Shared control-box background (surface bg, 1.5px border, rounded).
struct ControlBox: ViewModifier {
    let ctx: RenderCtx

    func body(content: Content) -> some View {
        content
            .background(ctx.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: ctx.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: ctx.cornerRadius)
                    .strokeBorder(ctx.border.color, lineWidth: 1.5))
    }
}

/// Dashed-border neutral placeholder used by lottie / paywall_handoff /
/// custom / unknown nodes.
func dashedPlaceholder(_ label: String, _ ctx: RenderCtx) -> AnyView {
    AnyView(
        Text(label)
            .font(.system(size: 12))
            .foregroundColor(ctx.textSecondary.color)
            .frame(maxWidth: .infinity)
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: ctx.cornerRadius)
                    .strokeBorder(
                        ctx.border.color,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    )
}

func renderUnknown(_ n: PrimNode) -> AnyView {
    AnyView(
        Text("⟨\(n.type)⟩")
            .font(.system(size: 12))
            .foregroundColor(Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    )
}
