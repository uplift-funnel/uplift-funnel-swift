import Foundation
import SwiftUI

// Action + selection nodes (Spec v2 §3.3), ported from `action_nodes.dart`:
// button, choice (6 layouts), photo_upload, swipe deck.

// MARK: - button

@MainActor
func renderButton(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let label = ctx.resolve(p["label"])
    let variant = p["variant"].stringValue ?? ctx.screenStyle.buttonVariant ?? "filled"
    let action = p["action"].stringValue ?? "next"
    let fullWidth = p["full_width"].boolValue == true

    let primary = ctx.primary

    var bg: RGBAColor
    var fg: RGBAColor
    var borderColor: RGBAColor?
    switch variant {
    case "outline":
        bg = .transparent
        fg = primary
        borderColor = primary
    case "soft":
        bg = primary.opacity(0.12)
        fg = primary
    case "ghost":
        bg = .transparent
        fg = primary
    default:  // filled
        bg = primary
        fg = ctx.onPrimary
    }

    // Explicit node.style overrides the variant defaults above (not the
    // other way around): a custom background/radius set in the Style panel
    // must not be clobbered by the variant switch.
    let styleBg = n.style["background"].stringValue
    if let styleBg { bg = ctx.color(styleBg) }
    // Art-directed CTAs: honor an explicit style.color for the label, or
    // derive a contrasting label from a custom background.
    if let styleFg = n.style["color"].stringValue {
        fg = ctx.color(styleFg)
    } else if styleBg != nil {
        fg = bg.isLight ? RGBAColor(hex: 0x0A0A0A) : .white
    }
    let radii = CornerRadii.parse(n.style["radius"]) ?? CornerRadii(all: ctx.cornerRadius)
    // Only `background` moves inline — `radius` STAYS in the style map so
    // applyStyle's box (border/shadow/padding) keeps the same rounding.
    var restStyle = n.style.objectValue ?? [:]
    restStyle["background"] = nil

    // A gated CTA reads as inactive and swallows taps until its condition
    // holds — the same evaluator the engine uses for transitions.
    let enabled = ctx.isEnabled(p["enabled_when"])
    let shape = RoundedCornersShape(radii: radii)

    var button = AnyView(
        Button {
            let context = ctx
            Task { await context.dispatchAction(action) }
        } label: {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(fg.color)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(shape.fill(bg.color))
                .overlay(
                    borderColor.map { shape.strokeBorder($0.color, lineWidth: 1.5) })
        }
        .buttonStyle(.plain)
        .disabled(!enabled))

    if !enabled {
        button = AnyView(button.opacity(0.45))
    }
    // Opt-in CTA emphasis: a subtle looping scale pulse. Suppressed under
    // reduce-motion, and while disabled — animating a button that can't be
    // tapped is a lie.
    if p["animate"].stringValue == "pulse", !ctx.reduceMotion, enabled {
        button = AnyView(PulseView { button })
    }
    return applyStyle(button, .object(restStyle), ctx)
}

/// A subtle looping scale pulse (button.props.animate == "pulse"), mirroring
/// the web keyframe (scale 1.0 ↔ 1.04).
struct PulseView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var pulsing = false

    var body: some View {
        content()
            .scaleEffect(pulsing ? 1.04 : 1.0)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - choice

@MainActor
func renderChoice(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    switch n.props["layout"].stringValue ?? "list" {
    case "grid": return renderChoiceGrid(n, ctx)
    case "chip": return renderChoiceChip(n, ctx)
    case "card": return renderChoiceCard(n, ctx)
    case "image_card": return renderChoiceImageCard(n, ctx)
    case "emoji": return renderChoiceEmoji(n, ctx)
    default: return renderChoiceList(n, ctx)
    }
}

func choiceOptions(_ n: PrimNode) -> [JSONValue] {
    (n.props["options"].arrayValue ?? []).filter { $0.objectValue != nil }
}

/// Selection state for one choice node — single (string equality) or multi
/// (membership in the JSON-array bound value). Pure struct so multi-select
/// semantics stay testable without UI.
struct ChoiceSelection {
    private let multi: Bool
    private let single: String?
    private let values: [String]

    init(_ n: PrimNode, _ ctx: RenderCtx) {
        multi = n.props["mode"].stringValue == "multi"
        single = ctx.boundValue(n.saveTo)
        values = multi ? ctx.boundValues(n.saveTo) : []
    }

    func contains(_ value: String) -> Bool {
        multi ? values.contains(value) : single == value
    }

    /// The next bound-variable value after toggling `value`, or nil when the
    /// tap is a no-op (`max` cap reached). Single-select returns the scalar;
    /// multi returns the JSON-array encoding.
    static func nextValue(
        current: [String], toggling value: String, max: Int?
    ) -> String? {
        var cur = current
        if let idx = cur.firstIndex(of: value) {
            cur.remove(at: idx)
        } else {
            if let max, cur.count >= max { return nil }
            cur.append(value)
        }
        return JSONValue.array(cur.map { .string($0) }).serializedString()
    }
}

@MainActor
func selectChoice(_ ctx: RenderCtx, _ n: PrimNode, _ value: String) {
    hapticSelection()
    let saveTo = n.saveTo
    if n.props["mode"].stringValue != "multi" {
        ctx.writeVar(saveTo, value)
        if n.props["auto_advance"].boolValue == true { ctx.onAction?("next") }
        return
    }
    // multi: toggle membership, enforce `max` as a hard cap, and never
    // auto-advance — a separate CTA button submits. `min` is advisory.
    if let next = ChoiceSelection.nextValue(
        current: ctx.boundValues(saveTo), toggling: value,
        max: n.props["max"].intValue) {
        ctx.writeVar(saveTo, next)
    }
}

/// Internal rather than private so the render-logic tests can assert on it,
/// matching `ChoiceSelection` and `extractPinned` in the same suite.
struct ChoiceOptionData {
    let label: String
    let description: String
    let icon: String?
    let imageUrl: String?
    let value: String

    init(_ opt: JSONValue, _ ctx: RenderCtx) {
        label = ctx.resolve(opt["label"])
        description = opt["description"].isNull ? "" : ctx.resolve(opt["description"])
        icon = opt["icon"].stringValue
        imageUrl = opt["image_url"].stringValue
        value = opt["value"].stringifiedValue ?? ""
    }
}

private func choiceChrome(
    _ n: PrimNode, _ ctx: RenderCtx
) -> (styleBg: String?, radii: CornerRadii, restStyle: JSONValue) {
    let styleBg = n.style["background"].stringValue
    let radii = CornerRadii.parse(n.style["radius"]) ?? CornerRadii(all: ctx.cornerRadius)
    // node.style applies to EACH option box, not an invisible outer wrapper.
    var rest = n.style.objectValue ?? [:]
    rest["background"] = nil
    return (styleBg, radii, .object(rest))
}

private func choiceTileFill(
    _ isSel: Bool, _ styleBg: String?, _ ctx: RenderCtx
) -> Color {
    if isSel { return ctx.primary.opacity(0.1).color }
    if let styleBg { return ctx.color(styleBg).color }
    return ctx.surface.color
}

/// Per-slot typography override from `choice.props.typography` (`label` /
/// `description` — same shape as plan_picker slots). Fields left unset keep
/// the layout's hardcoded defaults, so flows without overrides render
/// byte-identically.
private struct ChoiceTypo {
    let font: Font
    let color: Color

    init(
        _ n: PrimNode, _ ctx: RenderCtx, _ slot: String,
        size: Double, weight: Font.Weight, color: Color
    ) {
        let t = n.props["typography"][slot]
        let resolvedSize = t["size"].doubleValue ?? size
        let resolvedWeight = fontWeight(from: t["weight"].stringValue, fallback: weight)
        if let family = t["fontFamily"].stringValue {
            font = primFont(
                family: resolveFontFamilyAlias(family),
                size: resolvedSize, weight: resolvedWeight, italic: false)
        } else {
            font = .system(size: resolvedSize, weight: resolvedWeight)
        }
        self.color = t["color"].stringValue.map { ctx.color($0).color } ?? color
    }
}

/// layout `list` (default) — full-width rows, icon + label.
@MainActor
func renderChoiceList(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (styleBg, radii, restStyle) = choiceChrome(n, ctx)
    let shape = RoundedCornersShape(radii: radii)
    let labelTypo = ChoiceTypo(
        n, ctx, "label", size: 16, weight: .medium, color: ctx.textPrimary.color)
    let descTypo = ChoiceTypo(
        n, ctx, "description", size: 13, weight: .regular,
        color: ctx.textSecondary.color)

    return AnyView(
        VStack(spacing: 10) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, optJson in
                let opt = ChoiceOptionData(optJson, ctx)
                let isSel = selected.contains(opt.value)
                applyStyle(
                    Button {
                        selectChoice(ctx, n, opt.value)
                    } label: {
                        // A row with two lines of text reads better
                        // top-aligned; a single-line row still centres
                        // against its icon.
                        HStack(alignment: opt.description.isEmpty ? .center : .top, spacing: 12) {
                            if let icon = opt.icon, !icon.isEmpty {
                                Text(icon).font(.system(size: 20))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(opt.label)
                                    .font(labelTypo.font)
                                    .foregroundColor(labelTypo.color)
                                if !opt.description.isEmpty {
                                    Text(opt.description)
                                        .font(descTypo.font)
                                        .foregroundColor(descTypo.color)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(shape.fill(choiceTileFill(isSel, styleBg, ctx)))
                        .overlay(shape.strokeBorder(
                            isSel ? ctx.primary.color : ctx.border.color, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain),
                    restStyle, ctx)
            }
        })
}

/// layout `grid` — 2-column tiles, icon over label.
@MainActor
func renderChoiceGrid(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (styleBg, radii, restStyle) = choiceChrome(n, ctx)
    let shape = RoundedCornersShape(radii: radii)
    let rowCount = (options.count + 1) / 2
    let labelTypo = ChoiceTypo(
        n, ctx, "label", size: 15, weight: .medium, color: ctx.textPrimary.color)
    let descTypo = ChoiceTypo(
        n, ctx, "description", size: 12, weight: .regular,
        color: ctx.textSecondary.color)

    func tile(_ index: Int) -> AnyView {
        guard index < options.count else { return AnyView(Color.clear) }
        let opt = ChoiceOptionData(options[index], ctx)
        let isSel = selected.contains(opt.value)
        return applyStyle(
            Button {
                selectChoice(ctx, n, opt.value)
            } label: {
                VStack(spacing: opt.description.isEmpty ? 8 : 4) {
                    if let icon = opt.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 28))
                    }
                    Text(opt.label)
                        .font(labelTypo.font)
                        .multilineTextAlignment(.center)
                        .foregroundColor(labelTypo.color)
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(descTypo.font)
                            .multilineTextAlignment(.center)
                            .foregroundColor(descTypo.color)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(shape.fill(choiceTileFill(isSel, styleBg, ctx)))
                .overlay(shape.strokeBorder(
                    isSel ? ctx.primary.color : ctx.border.color, lineWidth: 1.5))
            }
            .buttonStyle(.plain),
            restStyle, ctx)
    }

    return AnyView(
        VStack(spacing: 10) {
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(spacing: 10) {
                    tile(r * 2)
                    tile(r * 2 + 1)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        })
}

/// layout `chip` — compact wrapped pills.
@MainActor
func renderChoiceChip(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (styleBg, _, restStyle) = choiceChrome(n, ctx)

    return AnyView(
        WrapHStack(
            items: options, spacing: 8, runSpacing: 8, alignment: .leading
        ) { _, optJson in
            let opt = ChoiceOptionData(optJson, ctx)
            let isSel = selected.contains(opt.value)
            // Base color keeps the chip's selected-state flip unless the
            // author pinned an explicit label color.
            let labelTypo = ChoiceTypo(
                n, ctx, "label", size: 14, weight: .medium,
                color: isSel ? ctx.primary.color : ctx.textPrimary.color)
            applyStyle(
                    Button {
                        selectChoice(ctx, n, opt.value)
                    } label: {
                        HStack(spacing: 6) {
                            if let icon = opt.icon, !icon.isEmpty {
                                Text(icon).font(.system(size: 15))
                            }
                            Text(opt.label)
                                .font(labelTypo.font)
                                .foregroundColor(labelTypo.color)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(
                            isSel
                                ? ctx.primary.opacity(0.12).color
                                : (styleBg.map { ctx.color($0).color } ?? ctx.surface.color)))
                        .overlay(Capsule().strokeBorder(
                            isSel ? ctx.primary.color : ctx.border.color, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain),
                    restStyle, ctx)
        })
}

/// layout `card` — full-width rows with a description line under the label.
@MainActor
func renderChoiceCard(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (styleBg, radii, restStyle) = choiceChrome(n, ctx)
    let shape = RoundedCornersShape(radii: radii)
    let labelTypo = ChoiceTypo(
        n, ctx, "label", size: 16, weight: .semibold, color: ctx.textPrimary.color)
    let descriptionTypo = ChoiceTypo(
        n, ctx, "description", size: 13, weight: .regular,
        color: ctx.textSecondary.color)

    return AnyView(
        VStack(spacing: 10) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, optJson in
                let opt = ChoiceOptionData(optJson, ctx)
                let isSel = selected.contains(opt.value)
                applyStyle(
                    Button {
                        selectChoice(ctx, n, opt.value)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            if let icon = opt.icon, !icon.isEmpty {
                                Text(icon).font(.system(size: 26))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(opt.label)
                                    .font(labelTypo.font)
                                    .foregroundColor(labelTypo.color)
                                if !opt.description.isEmpty {
                                    Text(opt.description)
                                        .font(descriptionTypo.font)
                                        .foregroundColor(descriptionTypo.color)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(shape.fill(choiceTileFill(isSel, styleBg, ctx)))
                        .overlay(shape.strokeBorder(
                            isSel ? ctx.primary.color : ctx.border.color, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain),
                    restStyle, ctx)
            }
        })
}

/// layout `image_card` — 2-column photo tiles, label overlaid on a scrim.
@MainActor
func renderChoiceImageCard(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (_, radii, restStyle) = choiceChrome(n, ctx)
    let shape = RoundedCornersShape(radii: radii)
    let rowCount = (options.count + 1) / 2

    func tile(_ index: Int) -> AnyView {
        guard index < options.count else { return AnyView(Color.clear) }
        let opt = ChoiceOptionData(options[index], ctx)
        let isSel = selected.contains(opt.value)
        let labelTypo = ChoiceTypo(
            n, ctx, "label", size: 15, weight: .semibold,
            color: opt.imageUrl != nil ? .white : ctx.textPrimary.color)
        let descTypo = ChoiceTypo(
            n, ctx, "description", size: 12, weight: .regular,
            // On a photo the scrim is dark, so the muted palette colour
            // disappears — step down from white instead.
            color: opt.imageUrl != nil ? Color.white.opacity(0.82) : ctx.textSecondary.color)
        return applyStyle(
            Button {
                selectChoice(ctx, n, opt.value)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if let imageUrl = opt.imageUrl, let url = URL(string: imageUrl) {
                        RemoteImage(url: url, contentMode: .fill)
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.05),
                                Color.black.opacity(0.55),
                            ],
                            startPoint: .top, endPoint: .bottom)
                    } else {
                        ctx.surface.color
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(opt.label)
                            .font(labelTypo.font)
                            .foregroundColor(labelTypo.color)
                        if !opt.description.isEmpty {
                            Text(opt.description)
                                .font(descTypo.font)
                                .foregroundColor(descTypo.color)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    isSel ? ctx.primary.color : Color.clear, lineWidth: 2))
            }
            .buttonStyle(.plain),
            restStyle, ctx)
    }

    return AnyView(
        VStack(spacing: 10) {
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(spacing: 10) {
                    tile(r * 2)
                    tile(r * 2 + 1)
                }
            }
        })
}

/// layout `emoji` — small squarish tiles, big emoji over a short label.
@MainActor
func renderChoiceEmoji(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let options = choiceOptions(n)
    let selected = ChoiceSelection(n, ctx)
    let (styleBg, radii, restStyle) = choiceChrome(n, ctx)
    let shape = RoundedCornersShape(radii: radii)
    let labelTypo = ChoiceTypo(
        n, ctx, "label", size: 12, weight: .medium, color: ctx.textPrimary.color)

    return AnyView(
        WrapHStack(
            items: options, spacing: 10, runSpacing: 10, alignment: .center
        ) { _, optJson in
            let opt = ChoiceOptionData(optJson, ctx)
            let isSel = selected.contains(opt.value)
            applyStyle(
                Button {
                    selectChoice(ctx, n, opt.value)
                } label: {
                    VStack(spacing: 6) {
                        Text((opt.icon?.isEmpty == false) ? opt.icon! : "•")
                            .font(.system(size: 32))
                        Text(opt.label)
                            .font(labelTypo.font)
                            .multilineTextAlignment(.center)
                            .foregroundColor(labelTypo.color)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 12)
                    .frame(width: 76)
                    .background(shape.fill(choiceTileFill(isSel, styleBg, ctx)))
                    .overlay(shape.strokeBorder(
                        isSel ? ctx.primary.color : ctx.border.color, lineWidth: 1.5))
                }
                .buttonStyle(.plain),
                restStyle, ctx)
        })
}

// MARK: - photo_upload

@MainActor
func renderPhotoUpload(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let has = ctx.boundValue(saveTo) != nil
    let circle = p["shape"].stringValue == "circle"
    let prompt = ctx.resolve(p["prompt"])
    let promptText = prompt.isEmpty ? "Add a photo" : prompt
    let radius = ctx.cornerRadius
    let handler = ctx.onPhotoUpload

    let content = VStack(spacing: 8) {
        Text(has ? "✓" : "📷").font(.system(size: 30))
        Text(has ? "Photo added" : promptText)
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .foregroundColor(ctx.textSecondary.color)
            .padding(.horizontal, 8)
    }

    let tile: AnyView
    if circle {
        tile = AnyView(
            content
                .frame(width: 140, height: 140)
                .background(Circle().fill(
                    has ? ctx.primary.opacity(0.08).color : ctx.surface.color))
                .overlay(Circle().strokeBorder(
                    has ? ctx.primary.color : ctx.border.color, lineWidth: 2)))
    } else {
        tile = AnyView(
            content
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: radius).fill(
                    has ? ctx.primary.opacity(0.08).color : ctx.surface.color))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                    has ? ctx.primary.color : ctx.border.color, lineWidth: 2)))
    }

    // Without a host picker there is nothing to pick: writing a placeholder
    // would let a flow "complete" with a photo that doesn't exist, so the
    // tile stays inert and says why in debug builds.
    return applyStyle(
        VStack(spacing: 6) {
            Button {
                guard let handler else { return }
                let context = ctx
                let request = PhotoUploadRequest(
                    source: p["source"].stringValue ?? "both",
                    shape: p["shape"].stringValue ?? "square")
                Task { @MainActor in
                    // Nil means the user backed out — leave the previous
                    // answer alone.
                    if let ref = await handler(request) {
                        context.writeVar(saveTo, ref)
                    }
                }
            } label: {
                circle ? AnyView(HStack { Spacer(); tile; Spacer() }) : tile
            }
            .buttonStyle(.plain)
            #if DEBUG
            if handler == nil {
                Text("No photo handler registered — call "
                     + "UpliftFunnel.registerPhotoUploadHandler().")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundColor(ctx.textSecondary.color)
            }
            #endif
        },
        n.style, ctx)
}

// MARK: - swipe

@MainActor
func renderSwipe(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let cards = (n.props["cards"].arrayValue ?? []).filter { $0.objectValue != nil }
    let radius = ctx.cornerRadius

    let topContent: AnyView
    if let first = cards.first, first["content"].objectValue != nil {
        topContent = renderNode(PrimNode(json: first["content"]), ctx)
    } else {
        topContent = AnyView(EmptyView())
    }
    let hasSecond = cards.count > 1

    let topCard = VStack(spacing: 12) {
        topContent
        HStack {
            Text("👈").font(.system(size: 22))
            Spacer(minLength: 0)
            Text("swipe")
                .font(.system(size: 12))
                .foregroundColor(ctx.textSecondary.color)
            Spacer(minLength: 0)
            Text("👉").font(.system(size: 22))
        }
    }
    .padding(14)
    .frame(maxWidth: .infinity)
    .background(RoundedRectangle(cornerRadius: radius).fill(ctx.surface.color))
    .overlay(RoundedRectangle(cornerRadius: radius)
        .strokeBorder(ctx.border.color, lineWidth: 1))
    .shadow(color: Color.black.opacity(0.06), radius: 6, y: 4)

    return applyStyle(
        ZStack {
            if hasSecond {
                RoundedRectangle(cornerRadius: radius)
                    .fill(ctx.surface.color)
                    .opacity(0.6)
                    .scaleEffect(0.96)
                    .offset(y: 8)
            }
            topCard
        },
        n.style, ctx)
}

// MARK: - Wrap layout (chips / emoji tiles)

/// Wrapping HStack for iOS 15 (the Layout protocol is iOS 16+): measures
/// children and breaks lines with alignment guides. The accumulators reset
/// on the LAST item so every layout pass starts clean.
struct WrapHStack<Item, ItemView: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let runSpacing: CGFloat
    let alignment: HorizontalAlignment
    @ViewBuilder let itemView: (Int, Item) -> ItemView

    @State private var totalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            wrappedContent(in: geometry)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: WrapHeightKey.self, value: inner.size.height)
                    })
        }
        .frame(height: totalHeight)
        .onPreferenceChange(WrapHeightKey.self) { totalHeight = $0 }
    }

    private func wrappedContent(in geometry: GeometryProxy) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0
        return ZStack(alignment: Alignment(horizontal: .leading, vertical: .top)) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                itemView(index, item)
                    .alignmentGuide(.leading) { d in
                        if abs(x - d.width) > geometry.size.width {
                            x = 0
                            y -= d.height + runSpacing
                        }
                        let result = x
                        if index == items.count - 1 {
                            x = 0
                        } else {
                            x -= d.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = y
                        if index == items.count - 1 { y = 0 }
                        return result
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }
}

private struct WrapHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
