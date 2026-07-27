import Foundation
import SwiftUI

// Content leaves (Spec v2 §3.2), ported from `content_nodes.dart`: text,
// rich_text, image, icon, media placeholders, progress, rating, countdown,
// testimonial, timeline.

/// TextStyle.textShadow → shadow parameters (distinct from applyStyle's
/// box-level shadow).
private struct TextShadowSpec {
    let color: RGBAColor
    let blur: Double
    let dx: Double
    let dy: Double

    init?(_ ts: JSONValue, _ ctx: RenderCtx) {
        guard ts.objectValue != nil else { return nil }
        color = ctx.color(
            ts["color"].stringValue, fallback: RGBAColor.black.opacity(0.35))
        blur = ts["blur"].doubleValue ?? 0
        dx = ts["offsetX"].doubleValue ?? 0
        dy = ts["offsetY"].doubleValue ?? 0
    }
}

private func baseTextStyle(
    _ n: PrimNode, _ ctx: RenderCtx, role: String
) -> TextSpanStyle {
    let ramp = ctx.ramp(role)
    let style = n.style
    return TextSpanStyle(
        size: style["size"].doubleValue ?? ramp.size,
        weight: fontWeight(from: style["weight"].stringValue, fallback: ramp.weight),
        color: ctx.color(
            style["color"].stringValue,
            fallback: ctx.color("text_primary", fallback: RGBAColor(hex: 0x0A0A0A))),
        family: resolveNodeFontFamily(
            style["fontFamily"].stringValue ?? ctx.screenStyle.fontFamily, ctx),
        italic: style["italic"].boolValue == true,
        decoration: style["decoration"].stringValue,
        letterSpacing: style["letterSpacing"].doubleValue)
}

/// Approximate Flutter's line-height multiplier: extra spacing beyond the
/// font's natural (~1.2×) line box.
private func lineSpacing(size: Double, multiplier: Double) -> Double {
    max(0, size * multiplier - size * 1.2)
}

// MARK: - text

@MainActor
func renderText(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let role = p["role"].stringValue ?? "body"
    let base = baseTextStyle(n, ctx, role: role)
    let ramp = ctx.ramp(role)
    let raw = ctx.resolve(p["value"])
    let align = swiftTextAlign(p["align"].stringValue ?? ctx.screenStyle.textAlign)
    let maxLines = p["max_lines"].intValue
    let heightMultiplier = n.style["lineHeight"].doubleValue ?? ramp.lineHeight
    let shadow = TextShadowSpec(n.style["textShadow"], ctx)

    var view = AnyView(
        Text(markdownLite(raw, base: base))
            .multilineTextAlignment(align)
            .lineSpacing(lineSpacing(size: base.size, multiplier: heightMultiplier))
            .lineLimit(maxLines))
    if ctx.parentAxis == .horizontal {
        // In a row, text hugs its content width (CSS `flex: 0 1 auto`):
        // expanding to .infinity would make a short "✓" glyph split the row
        // 50/50 with its sibling and squeeze the long text (the pup-academy
        // paywall bug). fixedSize(vertical) lets long text wrap onto more
        // lines instead of truncating with an ellipsis.
        view = AnyView(view.fixedSize(horizontal: false, vertical: true))
    } else {
        view = AnyView(view.frame(
            maxWidth: .infinity,
            alignment: frameAlignment(
                p["align"].stringValue ?? ctx.screenStyle.textAlign)))
    }
    if let shadow {
        view = AnyView(view.shadow(
            color: shadow.color.color, radius: shadow.blur / 2,
            x: shadow.dx, y: shadow.dy))
    }
    // Box styles (padding/background/radius/…) apply to text nodes too;
    // size/weight/color were consumed above — applyStyle ignores them.
    return applyStyle(view, n.style, ctx)
}

// MARK: - rich_text

/// rich_text → markdown-lite body text; blank lines split paragraphs.
@MainActor
func renderRichText(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let resolved = ctx.resolve(n.props["value"])
    let base = baseTextStyle(n, ctx, role: "body")
    let ramp = ctx.ramp("body")
    let align = swiftTextAlign(n.props["align"].stringValue ?? ctx.screenStyle.textAlign)
    let heightMultiplier = n.style["lineHeight"].doubleValue ?? ramp.lineHeight

    let blocks = splitParagraphs(resolved)
    return applyStyle(
        VStack(
            alignment: align == .center ? .center : .leading,
            spacing: base.size * 0.7
        ) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(markdownLite(block, base: base))
                    .multilineTextAlignment(align)
                    .lineSpacing(lineSpacing(size: base.size, multiplier: heightMultiplier))
            }
        },
        n.style, ctx)
}

private let paragraphSplitPattern = try! NSRegularExpression(pattern: #"\n{2,}"#)

/// Splits on runs of 2+ blank lines (paragraph breaks).
private func splitParagraphs(_ s: String) -> [String] {
    let range = NSRange(s.startIndex..., in: s)
    var result: [String] = []
    var last = s.startIndex
    for m in paragraphSplitPattern.matches(in: s, range: range) {
        guard let r = Range(m.range, in: s) else { continue }
        result.append(String(s[last..<r.lowerBound]))
        last = r.upperBound
    }
    result.append(String(s[last...]))
    return result
}

// MARK: - image

@MainActor
func renderImage(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let url = URL(string: ctx.resolve(p["url"]))
    let contain = p["fit"].stringValue == "contain"
    let height = p["height"].doubleValue
    let radius = p["radius"].doubleValue ?? 0

    var img = AnyView(
        RemoteImage(url: url, contentMode: contain ? .fit : .fill)
            .frame(maxWidth: .infinity)
            .frame(height: height.map { CGFloat($0) })
            .clipped())

    if height == nil, let ratio = parseRatio(p["ratio"].stringValue) {
        img = AnyView(img.aspectRatio(ratio, contentMode: .fit))
    }
    if radius > 0 {
        img = AnyView(img.clipShape(RoundedRectangle(cornerRadius: radius)))
    }
    return applyStyle(img, n.style, ctx)
}

// MARK: - icon

/// icon → emoji glyph or a named SF Symbol fallback.
@MainActor
func renderIconNode(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let size = p["size"].doubleValue ?? 24
    let color = ctx.color(p["color"].stringValue, fallback: ctx.textPrimary)
    let emoji = p["emoji"].stringValue
    let symbol = emoji == nil ? p["name"].stringValue.flatMap { namedIcons[$0] } : nil

    let view: AnyView
    if let symbol {
        view = AnyView(
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(color.color))
    } else {
        view = AnyView(
            Text(emoji ?? unknownGlyph)
                .font(.system(size: size))
                .foregroundColor(color.color))
    }
    return applyStyle(view, n.style, ctx)
}

// MARK: - video / lottie

/// video / lottie → static poster-or-gradient placeholder with a round
/// badge; a `video` with a URL upgrades to the real AVPlayer view (M6's
/// VideoNodeView) unless reduce-motion is on.
@MainActor
func renderMedia(_ n: PrimNode, _ ctx: RenderCtx, kind: String) -> AnyView {
    let p = n.props
    let poster = kind == "video" ? ctx.resolve(p["poster"]) : ""
    let radius = ctx.cornerRadius
    let badge = kind == "video" ? "▶" : "✦"

    let background: AnyView
    if !poster.isEmpty, let posterURL = URL(string: poster) {
        background = AnyView(RemoteImage(url: posterURL, contentMode: .fill))
    } else {
        background = AnyView(gradientBox(ctx))
    }

    let placeholder = AnyView(
        ZStack {
            background
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 46, height: 46)
                .overlay(
                    Text(badge)
                        .font(.system(size: 20))
                        .foregroundColor(ctx.primary.color))
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius)))

    let url = kind == "video" ? ctx.resolve(p["url"]) : ""
    if kind == "video", !url.isEmpty, !ctx.reduceMotion, let videoURL = URL(string: url) {
        let vh = p["height"].doubleValue ?? 160
        let vr = p["radius"].doubleValue ?? radius
        return applyStyle(
            VideoNodeView(
                url: videoURL,
                autoplay: p["autoplay"].boolValue == true,
                loop: p["loop"].boolValue == true,
                muted: p["muted"].boolValue != false,
                contain: p["fit"].stringValue == "contain",
                height: vh,
                radius: vr,
                placeholder: placeholder),
            n.style, ctx)
    }
    return applyStyle(placeholder, n.style, ctx)
}

func gradientBox(_ ctx: RenderCtx) -> some View {
    LinearGradient(
        colors: [ctx.primary.opacity(0.35).color, ctx.accent.opacity(0.12).color],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - progress

/// Fires the screen's default transition once, `durationMs` after it appears,
/// and renders its content unchanged.
struct AdvanceAfter: View {
    let durationMs: Int
    let ctx: RenderCtx
    let content: AnyView

    @State private var fired = false

    var body: some View {
        content.task {
            guard !fired else { return }
            fired = true
            let ns = UInt64(max(0, min(durationMs, 600_000))) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            ctx.onAction?("next")
        }
    }
}

@MainActor
func renderProgress(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let style = p["style"].stringValue ?? "bar"
    let value = p["value"].doubleValue ?? 0.6

    // spinner/percentage/steps draw no completion of their own, so they cannot
    // fire `advance_on_complete` the way the bar and the checklist do — and a
    // loading screen built on one is usually its screen's ONLY exit. Time it
    // out instead, or the screen is a dead end.
    let selfAdvancing = style == "bar" || style == "animated_list"
    let needsTimeout = p["advance_on_complete"].boolValue == true && !selfAdvancing
    func timed<V: View>(_ body: V) -> AnyView {
        guard needsTimeout else { return AnyView(body) }
        return AnyView(AdvanceAfter(
            durationMs: p["duration_ms"].intValue ?? 3000, ctx: ctx, content: AnyView(body)))
    }

    switch style {
    case "spinner":
        return applyStyle(
            timed(ProgressView()
                .progressViewStyle(.circular)
                .tint(ctx.primary.color)
                .scaleEffect(1.4)
                .frame(maxWidth: .infinity)
                .frame(height: 40)),
            n.style, ctx)
    case "percentage":
        return applyStyle(
            timed(Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(ctx.primary.color)
                .frame(maxWidth: .infinity)),
            n.style, ctx)
    case "steps":
        let steps = 4
        let done = Int((value * Double(steps)).rounded())
        return applyStyle(
            timed(HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule()
                        .fill(i < done ? ctx.primary.color : ctx.border.color)
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                }
            }),
            n.style, ctx)
    case "animated_list" where !(p["items"].arrayValue ?? []).isEmpty:
        return applyStyle(
            AnimatedChecklist(
                items: (p["items"].arrayValue ?? []).map { ctx.resolve($0) },
                durationMs: p["duration_ms"].intValue ?? 3000,
                advanceOnComplete: p["advance_on_complete"].boolValue == true,
                ctx: ctx),
            n.style, ctx)
    default:
        return applyStyle(
            TimedProgressBar(
                value: value,
                durationMs: p["duration_ms"].intValue,
                advanceOnComplete: p["advance_on_complete"].boolValue == true,
                ctx: ctx),
            n.style, ctx)
    }
}

/// The "setting things up" checklist: rows tick off in sequence across the
/// node's duration, then the flow advances if `advance_on_complete` is set.
/// Under reduce-motion every row renders already-checked.
struct AnimatedChecklist: View {
    let items: [String]
    let durationMs: Int
    let advanceOnComplete: Bool
    let ctx: RenderCtx

    @State private var done = 0
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 10) {
                    ZStack {
                        if i < done {
                            Circle().fill(ctx.primary.color)
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(ctx.onPrimary.color)
                        } else {
                            Circle().strokeBorder(ctx.border.color, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(item)
                        .font(.system(size: 15))
                        .foregroundColor(ctx.textPrimary.color)
                    Spacer(minLength: 0)
                }
                .opacity(i < done ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.3), value: done)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if ctx.reduceMotion {
                done = items.count
                return
            }
            let step = max(durationMs / max(items.count, 1), 1)
            for i in 0..<items.count {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(step * (i + 1)) * 1_000_000)
                    done = max(done, i + 1)
                }
            }
            if advanceOnComplete {
                let action = ctx
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
                    await action.dispatchAction("next")
                }
            }
        }
    }
}

/// Static at `value` when no duration; otherwise fills 0→1 over
/// `durationMs` and, when `advanceOnComplete` is set, fires the screen's
/// default transition exactly once on completion — this is what un-sticks
/// CTA-less loading screens on device.
struct TimedProgressBar: View {
    let value: Double
    let durationMs: Int?
    let advanceOnComplete: Bool
    let ctx: RenderCtx

    @State private var progress: Double = 0
    @State private var fired = false

    private var animated: Bool { (durationMs ?? 0) > 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ctx.border.color)
                Capsule()
                    .fill(ctx.primary.color)
                    .frame(width: proxy.size.width * (animated ? progress : value))
            }
        }
        .frame(height: 8)
        .onAppear {
            guard animated, !fired else { return }
            withAnimation(.linear(duration: Double(durationMs!) / 1000)) {
                progress = 1
            }
            let action = ctx
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(durationMs!) * 1_000_000)
                guard !fired else { return }
                fired = true
                if advanceOnComplete {
                    action.onAction?("next")
                }
            }
        }
    }
}

// MARK: - rating

@MainActor
func renderRating(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let saveTo = n.saveTo
    let max = p["max"].intValue ?? 5
    let current = ctx.boundValue(saveTo).flatMap { Double($0) }
        ?? p["value"].doubleValue ?? 0
    let interactive = saveTo != nil

    return applyStyle(
        HStack(spacing: 4) {
            ForEach(0..<max, id: \.self) { i in
                let star = Text("★")
                    .font(.system(size: 30))
                    .foregroundColor(
                        Double(i) < current
                            ? Color(.sRGB, red: 0xF5 / 255.0, green: 0xA6 / 255.0, blue: 0x23 / 255.0)
                            : ctx.border.color)
                if interactive {
                    Button {
                        ctx.writeVar(saveTo, "\(i + 1)")
                    } label: { star }
                    .buttonStyle(.plain)
                } else {
                    star
                }
            }
        }
        .frame(maxWidth: .infinity),
        n.style, ctx)
}

// MARK: - countdown

@MainActor
func renderCountdown(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    AnyView(CountdownNode(n: n, ctx: ctx))
}

/// Live countdown: anchors a deadline once (`target` absolute, or
/// `duration_ms` from first appearance) and ticks every second, stopping at
/// zero.
struct CountdownNode: View {
    let n: PrimNode
    let ctx: RenderCtx

    @State private var deadline: Date?
    @State private var totalSec: Int = 0

    private func resolveDeadline() -> (Date, Int) {
        let p = n.props
        let now = Date()
        let target = p["target"].stringValue
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let durationMs = p["duration_ms"].intValue
        let deadline: Date
        if let target {
            deadline = target
        } else if let durationMs {
            deadline = now.addingTimeInterval(Double(durationMs) / 1000)
        } else {
            deadline = now
        }
        let total = durationMs.map { $0 / 1000 }
            ?? max(Int(deadline.timeIntervalSince(now)), 0)
        return (deadline, total)
    }

    private func remaining(_ now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(Int(deadline.timeIntervalSince(now)), 0)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(now: timeline.date)
        }
        .onAppear {
            if deadline == nil {
                let (d, total) = resolveDeadline()
                deadline = d
                totalSec = total
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let style = n.props["style"].stringValue ?? "digits"
        let total = remaining(now)
        if style == "bar" {
            let frac = totalSec <= 0 ? 0 : min(max(Double(total) / Double(totalSec), 0), 1)
            applyStyle(
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ctx.errorColor.color.frame(width: proxy.size.width * frac)
                        ctx.border.color
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule()),
                n.style, ctx)
        } else {
            let hh = total / 3600
            let mm = (total / 60) % 60
            let ss = total % 60
            applyStyle(
                HStack(spacing: 8) {
                    if hh > 0 { digitCell(String(format: "%02d", hh)) }
                    digitCell(String(format: "%02d", mm))
                    digitCell(String(format: "%02d", ss))
                }
                .frame(maxWidth: .infinity),
                n.style, ctx)
        }
    }

    private func digitCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .bold).monospacedDigit())
            .foregroundColor(ctx.background.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(minWidth: 44)
            .background(ctx.textPrimary.color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - timeline

/// timeline: vertical step sequence with a connector line — the trial
/// roadmap ("Today → Day 5 → Day 7") / "how it works" pattern.
@MainActor
func renderTimeline(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let items = (n.props["items"].arrayValue ?? []).filter { $0.objectValue != nil }
    if items.isEmpty { return AnyView(EmptyView()) }

    return applyStyle(
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let icon = item["icon"].stringValue ?? ""
                let title = ctx.resolve(item["title"])
                let subtitle = ctx.resolve(item["subtitle"])
                let last = i == items.count - 1

                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(ctx.primary.opacity(0.12).color)
                            if icon.isEmpty {
                                Circle()
                                    .fill(ctx.primary.color)
                                    .frame(width: 10, height: 10)
                            } else {
                                Text(icon).font(.system(size: 14))
                            }
                        }
                        .frame(width: 28, height: 28)
                        if !last {
                            Rectangle()
                                .fill(ctx.primary.opacity(0.25).color)
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(ctx.textPrimary.color)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12.5))
                                .foregroundColor(ctx.textSecondary.color)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, last ? 0 : 18)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        },
        n.style, ctx)
}

// MARK: - testimonial

@MainActor
func renderTestimonial(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let author = ctx.resolve(p["author"])
    let quote = ctx.resolve(p["quote"])
    let avatar = ctx.resolve(p["avatar_url"])
    let rating = p["rating"].doubleValue ?? 0

    let stars: String
    if rating > 0 {
        let filled = Int(rating.rounded())
        stars = String(repeating: "★", count: filled)
            + String(repeating: "☆", count: max(5 - filled, 0))
    } else {
        stars = ""
    }

    return applyStyle(
        VStack(alignment: .leading, spacing: 10) {
            if !stars.isEmpty {
                Text(stars)
                    .font(.system(size: 15))
                    .foregroundColor(Color(.sRGB, red: 0xF5 / 255.0, green: 0xA6 / 255.0, blue: 0x23 / 255.0))
                    .kerning(2)
            }
            Text("“\(quote)”")
                .font(.system(size: 16))
                .lineSpacing(lineSpacing(size: 16, multiplier: 1.4))
                .foregroundColor(ctx.textPrimary.color)
            HStack(spacing: 8) {
                if !avatar.isEmpty, let avatarURL = URL(string: avatar) {
                    RemoteImage(url: avatarURL, contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                } else {
                    avatarInitial(author, ctx)
                }
                Text(author)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ctx.textSecondary.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ctx.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: ctx.cornerRadius)),
        n.style, ctx)
}

func avatarInitial(_ author: String, _ ctx: RenderCtx) -> some View {
    Circle()
        .fill(ctx.primary.color)
        .frame(width: 28, height: 28)
        .overlay(
            Text(author.isEmpty ? "?" : String(author.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(ctx.onPrimary.color))
}

// MARK: - compare

/// compare → interactive before/after. `mode` picks the interaction: a
/// draggable divider wiping left↔right (`horizontal`) or top↔bottom
/// (`vertical`), or a tap that swaps which image is shown (`toggle`).
@MainActor
func renderCompare(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let radius = p["radius"].doubleValue ?? 0
    let height = p["height"].doubleValue

    var view = AnyView(
        CompareBox(
            beforeURL: URL(string: ctx.resolve(p["before_url"])),
            afterURL: URL(string: ctx.resolve(p["after_url"])),
            beforeLabel: ctx.resolve(p["before_label"]),
            afterLabel: ctx.resolve(p["after_label"]),
            mode: p["mode"].stringValue ?? "horizontal",
            initialPosition: p["initial_position"].doubleValue ?? 0.5,
            contentMode: p["fit"].stringValue == "contain" ? .fit : .fill))

    // No intrinsic size: honor `height`, else derive it from `ratio`, else 3:4.
    //
    // NOT `.aspectRatio(_, contentMode: .fit)`: that leaves the box flexible in
    // BOTH axes, so a sibling `spacer{flex:1}` in the same VStack bargains it
    // down to a fraction of the column and the ratio then shrinks the width to
    // match — the box renders about half as wide as the web, which sets
    // `width:100%` and derives height. Claim the full width, measure it, and
    // set the height outright.
    view = AnyView(
        CompareRatioBox(
            explicitHeight: height.map { CGFloat($0) },
            ratio: CGFloat(parseRatio(p["ratio"].stringValue) ?? 3.0 / 4.0),
            content: view))
    if radius > 0 {
        view = AnyView(view.clipShape(RoundedRectangle(cornerRadius: radius)))
    }
    return applyStyle(view, n.style, ctx)
}

/// Full-width box whose height is either explicit or `width / ratio`.
///
/// Measuring the width and setting the height outright is what keeps a
/// ratio-sized node from negotiating its height away against a sibling
/// `Spacer` — see the note in `renderCompare`.
struct CompareRatioBox: View {
    let explicitHeight: CGFloat?
    let ratio: CGFloat
    let content: AnyView

    @State private var width: CGFloat = 0

    private var height: CGFloat? {
        if let explicitHeight { return explicitHeight }
        return width > 0 ? width / ratio : nil
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { width = $0 }
                })
    }
}

/// "W:H" → W/H. Nil when absent or malformed, so callers can default.
func parseRatio(_ ratio: String?) -> Double? {
    guard let ratio else { return nil }
    let parts = ratio.split(separator: ":")
    guard parts.count == 2,
          let w = Double(parts[0]), let h = Double(parts[1]), h != 0
    else { return nil }
    return w / h
}

struct CompareBox: View {
    let beforeURL: URL?
    let afterURL: URL?
    let beforeLabel: String
    let afterLabel: String
    let mode: String
    let initialPosition: Double
    let contentMode: ContentMode

    @State private var pos: Double?
    @State private var showAfter = false

    private var position: Double { (pos ?? initialPosition).clamped01 }
    private var horizontal: Bool { mode != "vertical" }

    var body: some View {
        if mode == "toggle" {
            // Same GeometryReader + explicit frame as the wipe modes: a `.fill`
            // RemoteImage overflows its box, and an unconstrained ZStack sizes
            // to that overflow — which pushed the badge and the hint outside
            // the visible (clipped) area entirely.
            GeometryReader { geo in
                let size = geo.size
                let label = showAfter ? afterLabel : beforeLabel
                ZStack(alignment: .topLeading) {
                    RemoteImage(url: showAfter ? afterURL : beforeURL,
                                contentMode: contentMode)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    if !label.isEmpty {
                        compareBadge(label).padding(10)
                    }
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            compareHint("Tap to compare")
                        }
                    }
                    .padding(10)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { showAfter.toggle() }
            }
        } else {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    RemoteImage(url: afterURL, contentMode: contentMode)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    RemoteImage(url: beforeURL, contentMode: contentMode)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .mask(alignment: horizontal ? .leading : .top) {
                            Rectangle().frame(
                                width: horizontal ? size.width * position : size.width,
                                height: horizontal ? size.height : size.height * position)
                        }

                    // Divider bar + knob, drawn at the wipe position.
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: horizontal ? 2 : size.width,
                               height: horizontal ? size.height : 2)
                        .offset(x: horizontal ? size.width * position - 1 : 0,
                                y: horizontal ? 0 : size.height * position - 1)
                    compareKnob(horizontal: horizontal)
                        .offset(
                            x: horizontal ? size.width * position - 16 : size.width / 2 - 16,
                            y: horizontal ? size.height / 2 - 16 : size.height * position - 16)

                    if !beforeLabel.isEmpty {
                        compareBadge(beforeLabel).padding(10)
                    }
                    if !afterLabel.isEmpty {
                        VStack {
                            if horizontal {
                                HStack { Spacer(); compareBadge(afterLabel) }
                                Spacer()
                            } else {
                                Spacer()
                                HStack { compareBadge(afterLabel); Spacer() }
                            }
                        }
                        .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let raw = horizontal
                                ? (size.width == 0 ? 0.5 : value.location.x / size.width)
                                : (size.height == 0 ? 0.5 : value.location.y / size.height)
                            pos = Double(raw).clamped01
                        })
            }
        }
    }
}

/// Raw colors, not theme tokens: these sit on top of a photo, where a theme
/// text color can land invisible.
func compareBadge(_ label: String) -> some View {
    Text(label)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
}

func compareHint(_ label: String) -> some View {
    Text(label)
        .font(.system(size: 11))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
}

func compareKnob(horizontal: Bool) -> some View {
    Circle()
        .fill(Color.white)
        .frame(width: 32, height: 32)
        .shadow(color: Color.black.opacity(0.2), radius: 3, y: 2)
        .overlay(
            Text(horizontal ? "↔" : "↕")
                .font(.system(size: 15))
                .foregroundColor(Color(.sRGB, red: 0x18 / 255.0, green: 0x18 / 255.0,
                                       blue: 0x1B / 255.0)))
}

extension Double {
    fileprivate var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
