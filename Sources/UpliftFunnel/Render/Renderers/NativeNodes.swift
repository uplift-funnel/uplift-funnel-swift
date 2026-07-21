import Foundation
import SwiftUI

// Behavioral / native-handoff nodes (Spec v2 §3.5), ported from
// `native_nodes.dart`: permission, signin, paywall_handoff, plan_picker,
// custom.

// MARK: - signin

/// Platform-standard button copy per provider (overridable via `label`).
let signInLabels: [String: String] = [
    "apple": "Continue with Apple",
    "google": "Continue with Google",
    "facebook": "Continue with Facebook",
    "email": "Continue with Email",
    "anonymous": "Continue as guest",
]

@MainActor
func renderSignIn(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let providers = (p["providers"].arrayValue ?? []).filter { $0.objectValue != nil }
    let appearance = p["appearance"].stringValue ?? "auto"
    let advance = p["advance_on_success"].boolValue != false
    // auto = dark buttons on a light screen, light buttons on a dark screen.
    let darkScheme = appearance == "dark"
        || (appearance != "light" && ctx.background.isLight)
    let radius = ctx.cornerRadius
    let done = ctx.boundValue(saveTo)

    func pick(_ provider: String) {
        let context = ctx
        Task { @MainActor in
            if let handler = context.onSignIn {
                let ok = await handler(provider)
                if !ok { return }
            }
            context.writeVar(saveTo, provider)
            if advance { context.onAction?("next") }
        }
    }

    return applyStyle(
        VStack(spacing: 10) {
            ForEach(Array(providers.enumerated()), id: \.offset) { _, entry in
                let provider = entry["provider"].stringValue ?? "email"
                let labelOverride = ctx.resolve(entry["label"])
                let label = labelOverride.isEmpty
                    ? (signInLabels[provider] ?? "Continue with \(provider)")
                    : labelOverride

                SignInButton(
                    provider: provider, label: label, darkScheme: darkScheme,
                    radius: radius, isDone: done == provider, ctx: ctx
                ) { pick(provider) }
            }
        },
        n.style, ctx)
}

private struct SignInButton: View {
    let provider: String
    let label: String
    let darkScheme: Bool
    let radius: Double
    let isDone: Bool
    let ctx: RenderCtx
    let action: () -> Void

    var body: some View {
        let (bg, fg, borderColor) = colors
        Button(action: action) {
            HStack(spacing: 8) {
                logo(fg: fg)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(fg.color)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius).fill(bg.color))
            .overlay(
                RoundedRectangle(cornerRadius: radius).strokeBorder(
                    isDone ? ctx.success.color : (borderColor?.color ?? Color.clear),
                    lineWidth: isDone ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var colors: (bg: RGBAColor, fg: RGBAColor, border: RGBAColor?) {
        switch provider {
        case "apple":  // Apple HIG: black button, or white on dark screens.
            return darkScheme
                ? (.black, .white, nil)
                : (.white, RGBAColor(hex: 0x0A0A0A), nil)
        case "google":  // Google branding: white button + subtle border.
            return (.white, RGBAColor(hex: 0x1F1F1F), RGBAColor(hex: 0xDADCE0))
        case "facebook":
            return (RGBAColor(hex: 0x1877F2), .white, nil)
        case "anonymous":
            return (.transparent, ctx.textSecondary, nil)
        default:  // email
            return (ctx.surface, ctx.textPrimary, ctx.border)
        }
    }

    @ViewBuilder
    private func logo(fg: RGBAColor) -> some View {
        switch provider {
        case "apple":
            Image(systemName: "apple.logo")
                .font(.system(size: 17))
                .foregroundColor(fg.color)
        case "google":
            Text("G")
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(Color(.sRGB, red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0))
        case "facebook":
            Text("f")
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(.white)
        case "anonymous":
            EmptyView()
        default:
            Image(systemName: "envelope")
                .font(.system(size: 16))
                .foregroundColor(fg.color)
        }
    }
}

// MARK: - permission

/// Copy the OS shows for each permission, so the stand-in reads like the
/// real prompt rather than a generic confirm.
let permissionPrompts: [String: String] = [
    "camera": "This lets you take photos inside the app.",
    "photos": "Select photos to use in the app.",
    "health": "Read and write your health data.",
    "location": "Use your location to personalize results.",
    "microphone": "Record audio inside the app.",
    "contacts": "Find friends already using the app.",
    "notifications": "Notifications may include alerts, sounds and icon "
        + "badges. These can be configured in Settings.",
    "calendar": "Add events and reminders to your calendar.",
    "tracking": "This allows the app to track your activity across other "
        + "companies' apps and websites.",
]

@MainActor
func renderPermission(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    applyStyle(PermissionNodeView(n: n, ctx: ctx), n.style, ctx)
}

struct PermissionNodeView: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var showingStandIn = false

    var body: some View {
        let p = n.props
        let perm = p["permission"].stringValue ?? ""
        let meta = permissionMeta[perm]
            ?? (emoji: "🔐", label: perm.isEmpty ? "Permission" : perm)
        let granted = ctx.boundValue(n.saveTo) == "true"
        let advance = p["advance_on_result"].boolValue != false

        VStack(spacing: 12) {
            Text(meta.emoji).font(.system(size: 40))
            Text("Allow \(meta.label) access")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(ctx.textPrimary.color)
            Button {
                // Hand off to the host's permission handler (the real OS
                // dialog) when one is registered. Without one, show a
                // stand-in alert rather than granting silently: an
                // auto-grant makes the deny branch untestable.
                if let handler = ctx.onPermission {
                    let context = ctx
                    Task { @MainActor in
                        let ok = await handler(perm)
                        context.writeVar(n.saveTo, ok ? "true" : "false")
                        if advance { context.onAction?("next") }
                    }
                } else {
                    showingStandIn = true
                }
            } label: {
                Text(granted ? "✓ Allowed" : "Allow")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ctx.onPrimary.color)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: ctx.cornerRadius)
                            .fill(granted ? ctx.success.color : ctx.primary.color))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .alert(
            "Allow access to your \(meta.label.lowercased())?",
            isPresented: $showingStandIn
        ) {
            Button("Don't Allow", role: .cancel) { resolveStandIn(false, advance: advance) }
            Button("Allow") { resolveStandIn(true, advance: advance) }
        } message: {
            Text(permissionPrompts[perm]
                 ?? "This lets the app use your \(meta.label.lowercased()).")
        }
    }

    private func resolveStandIn(_ ok: Bool, advance: Bool) {
        ctx.writeVar(n.saveTo, ok ? "true" : "false")
        if advance { ctx.onAction?("next") }
    }
}

// MARK: - paywall_handoff

@MainActor
func renderPaywallHandoff(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let provider = p["provider"].stringValue ?? "—"
    let productIds = (p["product_ids"].arrayValue ?? [])
        .compactMap { $0.stringifiedValue }
    let radius = ctx.cornerRadius

    return applyStyle(
        VStack(spacing: 6) {
            Text("💳").font(.system(size: 22))
            Text("paywall handoff (\(provider))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ctx.textPrimary.color)
            if !productIds.isEmpty {
                Text(productIds.joined(separator: ", "))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(ctx.textSecondary.color)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: radius).fill(ctx.surface.color))
        .overlay(
            RoundedRectangle(cornerRadius: radius).strokeBorder(
                ctx.border.color,
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))),
        n.style, ctx)
}

// MARK: - plan_picker

/// Runtime product variable (`<field>.<productId>`) when the plan is bound
/// to a store product and the host injected a catalog value for it; else
/// the authored value resolves as usual.
func planDisplay(
    _ ctx: RenderCtx, field: String, productId: String?, authored: JSONValue
) -> String {
    if let productId, let v = ctx.vars["\(field).\(productId)"], !v.isEmpty {
        return v
    }
    return ctx.resolve(authored)
}

/// Resolved display data for one plan, shared by every layout. Price and
/// original price auto-bind to the runtime product catalog via the plan's
/// store product id (see `UpliftFunnel.setProducts`).
struct PlanData {
    let id: String
    let label: String
    let price: String
    let period: String
    let originalPrice: String
    let description: String
    let badge: String
    let highlighted: Bool
    let features: [String]

    init(_ pl: JSONValue, _ ctx: RenderCtx) {
        id = pl["id"].stringifiedValue ?? ""
        label = ctx.resolve(pl["label"])
        period = ctx.resolve(pl["period"])
        description = ctx.resolve(pl["description"])
        badge = ctx.resolve(pl["badge"])
        highlighted = pl["highlighted"].boolValue == true
        price = planDisplay(
            ctx, field: "price", productId: planProductId(pl), authored: pl["price"])
        originalPrice = planDisplay(
            ctx, field: "original_price", productId: planProductId(pl),
            authored: pl["original_price"])
        features = (pl["features"].arrayValue ?? [])
            .map { ctx.resolve($0) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
func renderPlanPicker(_ n: PrimNode, _ ctxBase: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo

    // Per-picker art direction: `accent` recolors selection/badge/check;
    // `appearance:"dark"` switches cards to a translucent-on-dark scheme.
    // Derived into a shadowed ctx so every layout below picks it up. When
    // neither prop is set ctx == ctxBase, so default pickers render
    // identically.
    let accent = p["accent"].stringValue
    let dark = p["appearance"].stringValue == "dark"
    let ctx = ((accent?.isEmpty == false) || dark)
        ? planArtCtx(ctxBase, accent: accent, dark: dark)
        : ctxBase

    let plans = (p["plans"].arrayValue ?? [])
        .filter { $0.objectValue != nil }
        .map { PlanData($0, ctx) }

    var selected = ctx.boundValue(saveTo)
    if selected == nil {
        selected = plans.first { $0.highlighted }?.id
    }

    let layout = p["layout"].stringValue ?? "cards"
    let body: AnyView
    switch layout {
    case "list":
        body = planListLayout(plans, selected, saveTo, ctx)
    case "horizontal":
        body = planHorizontalLayout(plans, selected, saveTo, ctx)
    case "toggle":
        body = planToggleLayout(
            plans, selected, saveTo, ctx,
            detailMode: p["detail"].stringValue ?? "card")
    default:
        body = planCardsLayout(plans, selected, saveTo, ctx)
    }
    return applyStyle(body, n.style, ctxBase)
}

/// Builds the art-directed RenderCtx for a plan_picker: overrides the theme
/// `accent` (→ primary/selected/badge) and, under `appearance:"dark"`, the
/// neutral card colors to a translucent-on-dark scheme.
func planArtCtx(_ base: RenderCtx, accent: String?, dark: Bool) -> RenderCtx {
    var colors = base.theme.colors
    if dark {
        colors["surface"] = "rgba(255,255,255,0.06)"
        colors["border"] = "rgba(255,255,255,0.18)"
        colors["background"] = "rgba(255,255,255,0.14)"
        colors["text_primary"] = "#ffffff"
        colors["text_secondary"] = "rgba(255,255,255,0.62)"
    }
    var themeTokens: [String: JSONValue] = [
        "colors": .object(colors.mapValues { .string($0) }),
        "shape": .object([
            "corner_radius": .number(base.theme.cornerRadius),
            "shadow_style": .string(base.theme.shadowStyle),
        ]),
        "spacing": .object(["unit": .number(base.theme.spacingUnit)]),
        "typography": .object(["font_family": .string(base.theme.fontFamily)]),
    ]
    _ = themeTokens  // silence mutation warning path below
    var ctx = base
    ctx.theme = PrimTheme(tokens: .object(themeTokens))
    if let accent, !accent.isEmpty {
        var screenStyle = base.screenStyle
        screenStyle.accent = accent
        ctx.screenStyle = screenStyle
    }
    return ctx
}

/// `cards` (default): stacked full-width cards.
@MainActor
private func planCardsLayout(
    _ plans: [PlanData], _ selected: String?, _ saveTo: String?, _ ctx: RenderCtx
) -> AnyView {
    let radius = ctx.cornerRadius
    return AnyView(
        VStack(spacing: 0) {
            ForEach(Array(plans.enumerated()), id: \.offset) { i, pl in
                let sel = selected == pl.id
                if i > 0 {
                    Spacer().frame(height: pl.badge.isEmpty ? 10 : 14)
                }
                withPlanBadge(
                    Button {
                        ctx.writeVar(saveTo, pl.id)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.label)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(ctx.textPrimary.color)
                                if !pl.description.isEmpty {
                                    Text(pl.description)
                                        .font(.system(size: 12))
                                        .foregroundColor(ctx.textSecondary.color)
                                }
                                if !pl.features.isEmpty {
                                    planFeatures(pl.features, ctx)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                if !pl.originalPrice.isEmpty {
                                    Text(pl.originalPrice)
                                        .font(.system(size: 13))
                                        .strikethrough()
                                        .foregroundColor(ctx.textSecondary.color)
                                        .padding(.trailing, 3)
                                }
                                Text(pl.price)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(ctx.textPrimary.color)
                                if !pl.period.isEmpty {
                                    Text(pl.period)
                                        .font(.system(size: 12))
                                        .foregroundColor(ctx.textSecondary.color)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: radius).fill(
                            sel ? ctx.primary.opacity(0.08).color : ctx.surface.color))
                        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                            sel ? ctx.primary.color : ctx.border.color, lineWidth: 2))
                    }
                    .buttonStyle(.plain),
                    badge: pl.badge, ctx)
            }
        })
}

/// `list`: compact radio rows — dense pickers with many tiers.
@MainActor
private func planListLayout(
    _ plans: [PlanData], _ selected: String?, _ saveTo: String?, _ ctx: RenderCtx
) -> AnyView {
    let radius = ctx.cornerRadius
    return AnyView(
        VStack(spacing: 8) {
            ForEach(Array(plans.enumerated()), id: \.offset) { _, pl in
                let sel = selected == pl.id
                Button {
                    ctx.writeVar(saveTo, pl.id)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            planRadio(sel, ctx)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Text(pl.label)
                                        .font(.system(size: 15, weight: .bold))
                                        .lineLimit(1)
                                        .foregroundColor(ctx.textPrimary.color)
                                    if !pl.badge.isEmpty {
                                        planBadgePill(pl.badge, ctx)
                                    }
                                }
                                if !pl.description.isEmpty {
                                    Text(pl.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(ctx.textSecondary.color)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                if !pl.originalPrice.isEmpty {
                                    Text(pl.originalPrice)
                                        .font(.system(size: 12))
                                        .strikethrough()
                                        .foregroundColor(ctx.textSecondary.color)
                                        .padding(.trailing, 2)
                                }
                                Text(pl.price)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(ctx.textPrimary.color)
                                if !pl.period.isEmpty {
                                    Text(pl.period)
                                        .font(.system(size: 11))
                                        .foregroundColor(ctx.textSecondary.color)
                                }
                            }
                        }
                        if !pl.features.isEmpty {
                            planFeatures(pl.features, ctx, fontSize: 11)
                                .padding(.leading, 28)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: radius).fill(
                        sel ? ctx.primary.opacity(0.06).color : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                        sel ? ctx.primary.color : ctx.border.color,
                        lineWidth: sel ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        })
}

/// `horizontal`: side-by-side columns (2-3 plans) — the classic tier row.
@MainActor
private func planHorizontalLayout(
    _ plans: [PlanData], _ selected: String?, _ saveTo: String?, _ ctx: RenderCtx
) -> AnyView {
    let radius = ctx.cornerRadius
    let anyBadge = plans.contains { !$0.badge.isEmpty }
    return AnyView(
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(plans.enumerated()), id: \.offset) { _, pl in
                let sel = selected == pl.id
                withPlanBadge(
                    Button {
                        ctx.writeVar(saveTo, pl.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pl.label)
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                                .foregroundColor(ctx.textPrimary.color)
                                .padding(.bottom, 6)
                            if !pl.originalPrice.isEmpty {
                                Text(pl.originalPrice)
                                    .font(.system(size: 12))
                                    .strikethrough()
                                    .foregroundColor(ctx.textSecondary.color)
                            }
                            Text(pl.price)
                                .font(.system(size: 19, weight: .heavy))
                                .foregroundColor(ctx.textPrimary.color)
                            if !pl.period.isEmpty {
                                Text(pl.period)
                                    .font(.system(size: 11))
                                    .foregroundColor(ctx.textSecondary.color)
                            }
                            if !pl.description.isEmpty {
                                Text(pl.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(ctx.textSecondary.color)
                                    .padding(.top, 6)
                            }
                            if !pl.features.isEmpty {
                                planFeatures(pl.features, ctx, fontSize: 11)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                               alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: radius).fill(
                            sel ? ctx.primary.opacity(0.08).color : ctx.surface.color))
                        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                            sel ? ctx.primary.color : ctx.border.color, lineWidth: 2))
                    }
                    .buttonStyle(.plain),
                    badge: pl.badge, ctx)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Headroom so badge pills riding the top edge don't clip.
        .padding(.top, anyBadge ? 9 : 0))
}

/// `toggle`: segmented period switch + one detail card for the selected
/// plan — the Calm/Headspace monthly-vs-yearly pattern.
@MainActor
private func planToggleLayout(
    _ plans: [PlanData], _ selected: String?, _ saveTo: String?, _ ctx: RenderCtx,
    detailMode: String
) -> AnyView {
    guard !plans.isEmpty else { return AnyView(EmptyView()) }
    let radius = ctx.cornerRadius
    let current = plans.first { $0.id == selected } ?? plans[0]

    let segments = HStack(spacing: 0) {
        ForEach(Array(plans.enumerated()), id: \.offset) { _, pl in
            let isCur = pl.id == current.id
            Button {
                ctx.writeVar(saveTo, pl.id)
            } label: {
                Text(pl.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(
                        isCur ? ctx.textPrimary.color : ctx.textSecondary.color)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(isCur ? ctx.background.color : Color.clear)
                            .shadow(color: isCur ? Color.black.opacity(0.25) : .clear,
                                    radius: 1, y: 1))
            }
            .buttonStyle(.plain)
        }
    }
    .padding(4)
    .background(Capsule().fill(ctx.surface.color))

    let priceRow = HStack(alignment: .firstTextBaseline, spacing: 4) {
        if !current.originalPrice.isEmpty {
            Text(current.originalPrice)
                .font(.system(size: 13))
                .strikethrough()
                .foregroundColor(ctx.textSecondary.color)
                .padding(.trailing, 2)
        }
        Text(current.price)
            .font(.system(size: detailMode == "inline" ? 17 : 24, weight: .heavy))
            .foregroundColor(ctx.textPrimary.color)
        if !current.period.isEmpty {
            Text(current.period)
                .font(.system(size: detailMode == "inline" ? 12 : 13))
                .foregroundColor(ctx.textSecondary.color)
        }
    }

    let detail: AnyView
    if detailMode == "inline" {
        detail = AnyView(
            HStack {
                HStack(spacing: 6) {
                    Text(current.label)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                        .foregroundColor(ctx.textPrimary.color)
                    if !current.badge.isEmpty { planBadgePill(current.badge, ctx) }
                }
                Spacer(minLength: 8)
                priceRow
            }
            .padding(EdgeInsets(top: 2, leading: 4, bottom: 0, trailing: 4)))
    } else {
        detail = AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(current.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(ctx.textPrimary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !current.badge.isEmpty { planBadgePill(current.badge, ctx) }
                }
                priceRow
                if !current.description.isEmpty {
                    Text(current.description)
                        .font(.system(size: 12))
                        .foregroundColor(ctx.textSecondary.color)
                }
                if !current.features.isEmpty {
                    planFeatures(current.features, ctx)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(ctx.primary.opacity(0.06).color))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(ctx.primary.color, lineWidth: 2)))
    }

    return AnyView(
        VStack(spacing: 12) {
            segments
            detail
        })
}

/// Badge pill riding a plan card's top edge (paywall convention).
@ViewBuilder
func withPlanBadge<Card: View>(_ card: Card, badge: String, _ ctx: RenderCtx) -> some View {
    if badge.isEmpty {
        card
    } else {
        card.overlay(alignment: .topTrailing) {
            planBadgePill(badge, ctx)
                .offset(x: -14, y: -9)
        }
    }
}

func planBadgePill(_ badge: String, _ ctx: RenderCtx) -> some View {
    Text(badge.uppercased())
        .font(.system(size: 10, weight: .heavy))
        .kerning(0.4)
        .foregroundColor(ctx.onPrimary.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(ctx.primary.color))
}

/// Checkmark bullet lines inside a plan card.
func planFeatures(_ features: [String], _ ctx: RenderCtx, fontSize: Double = 12) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(features.enumerated()), id: \.offset) { _, f in
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(ctx.primary.color)
                    .padding(.top, 1)
                Text(f)
                    .font(.system(size: fontSize))
                    .foregroundColor(ctx.textSecondary.color)
            }
        }
    }
    .padding(.top, 4)
}

/// Radio indicator for the `list` layout.
func planRadio(_ sel: Bool, _ ctx: RenderCtx) -> some View {
    ZStack {
        Circle()
            .strokeBorder(sel ? ctx.primary.color : ctx.border.color, lineWidth: 2)
        if sel {
            Circle().fill(ctx.primary.color).frame(width: 8, height: 8)
        }
    }
    .frame(width: 18, height: 18)
}

// MARK: - custom

@MainActor
func renderCustom(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let name = n.props["component_name"].stringValue ?? "?"
    return applyStyle(
        Text("custom: \(name)")
            .font(.system(size: 13))
            .foregroundColor(ctx.textSecondary.color)
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: ctx.cornerRadius)
                    .strokeBorder(
                        ctx.border.color,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))),
        n.style, ctx)
}
