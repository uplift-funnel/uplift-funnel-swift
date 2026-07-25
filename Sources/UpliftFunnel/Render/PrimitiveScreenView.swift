import Foundation
import SwiftUI

// A single primitive-tree screen, ported from `primitive_screen.dart`:
// full-bleed background layers + top-bar chrome + the `root` tree laid out
// inside the safe area, with pin_bottom CTAs extracted to a sticky footer.

/// Archetypes whose screens must never show a back chevron, regardless of
/// session history or `top_bar.back` (mirrors the dashboard editor rule).
let noBackArchetypes: Set<String> = ["plan_picker", "paywall_handoff"]

/// Depth-first finds the first `plan_picker` node's `bind.save_to` — the
/// variable the screen's `purchase` action reads the selected plan id from.
func findPlanSaveTo(_ node: PrimNode) -> String? {
    if node.type == "plan_picker" { return node.saveTo }
    for child in node.children {
        if let found = findPlanSaveTo(child) { return found }
    }
    return nil
}

/// Depth-first collects `button` nodes with `props.pin_bottom == true` and
/// returns the tree without them. Carousel/swipe subtrees are left intact —
/// a slide-local CTA can't meaningfully pin to the screen.
func extractPinned(_ node: PrimNode) -> (kept: PrimNode?, pinned: [PrimNode]) {
    if node.type == "button", node.props["pin_bottom"].boolValue == true {
        return (nil, [node])
    }
    if node.children.isEmpty || node.type == "carousel" || node.type == "swipe" {
        return (node, [])
    }
    var pinned: [PrimNode] = []
    var kept: [PrimNode] = []
    var changed = false
    for child in node.children {
        let (keptChild, childPinned) = extractPinned(child)
        if let keptChild { kept.append(keptChild) }
        if childPinned.isEmpty == false || keptChild == nil { changed = true }
        pinned.append(contentsOf: childPinned)
    }
    if !changed { return (node, []) }
    return (
        PrimNode(
            type: node.type, id: node.id, style: node.style,
            props: node.props, children: kept, bind: node.bind),
        pinned)
}

/// Renders `flow.screens[screenIndex]` in the given locale with `vars`
/// interpolation. Callbacks receive interaction events; `canGoBack` shows a
/// leading back chevron wired to `onAction("back")`.
struct PrimitiveScreenView: View {
    let flow: PrimFlow
    /// Effective theme (already resolved against the color scheme).
    let theme: PrimTheme
    let screenIndex: Int
    let locale: String
    var vars: [String: String] = [:]
    var selections: [String: String] = [:]
    var canGoBack = false
    var onAction: ((String) -> Void)?
    var onSave: ((String, String) -> Void)?
    /// Per-keystroke save path (no analytics emit) — see `RenderCtx.onSaveLocal`.
    var onSaveLocal: ((String, String) -> Void)?
    /// Editing-end commit path (dirty-aware flush) — see `RenderCtx.onSaveCommit`.
    var onSaveCommit: ((String, String) -> Void)?
    var onSignIn: ((String) async -> Bool)?
    var onPermission: ((String) async -> Bool)?
    var onPhotoUpload: ((PhotoUploadRequest) async -> String?)?
    var onPurchase: ((String?) async -> Bool)?
    var onRestore: (() async -> Bool)?
    var reduceMotion = false

    var body: some View {
        let screen = flow.screens[screenIndex]
        var ctx = RenderCtx(
            theme: theme,
            locale: locale,
            defaultLocale: flow.defaultLocale,
            localizations: flow.localizations,
            vars: vars)
        ctx.selections = selections
        ctx.onAction = onAction
        ctx.onSave = onSave
        ctx.onSaveLocal = onSaveLocal
        ctx.onSaveCommit = onSaveCommit
        ctx.onSignIn = onSignIn
        ctx.onPermission = onPermission
        ctx.onPhotoUpload = onPhotoUpload
        ctx.onPurchase = onPurchase
        ctx.onRestore = onRestore
        // The `purchase` action reads the selected plan from the screen's
        // plan_picker binding.
        ctx.planSaveTo = screen.root.flatMap { findPlanSaveTo($0) }
        ctx.screenStyle = ScreenStyleOverrides(style: screen.style)
        ctx.reduceMotion = reduceMotion

        return content(screen: screen, ctx: ctx)
            // Markdown action-links (`[Terms](url:…)`, `[Restore](restore)`)
            // route through the exact same dispatchAction as buttons.
            .environment(\.openURL, OpenURLAction { url in
                guard let action = ActionLink.action(from: url) else {
                    return .systemAction
                }
                let context = ctx
                Task { await context.dispatchAction(action) }
                return .handled
            })
    }

    @ViewBuilder
    private func content(screen: PrimScreen, ctx: RenderCtx) -> some View {
        // Screen-level style.background overrides the theme color and paints
        // the FULL frame (behind status bar / safe areas). Accepts a theme
        // token, a flat CSS color, or a `linear-gradient(...)` string.
        let styleBg = screen.style["background"].stringValue
        let bgSpec = (styleBg != nil && ctx.theme.colors[styleBg!] == nil)
            ? CssBackground.parse(styleBg!)
            : nil
        let backgroundColor: RGBAColor = {
            if let styleBg {
                if case .linearGradient(_, let colors, _)? = bgSpec {
                    // Flat stand-in where a gradient can't paint (footer strip).
                    return colors.last ?? ctx.background
                }
                return ctx.color(styleBg, fallback: ctx.background)
            }
            return ctx.color("background", fallback: .white)
        }()

        // pin_bottom buttons live OUTSIDE the scroll area — split them out
        // so the body scrolls independently underneath the sticky footer.
        let (bodyRoot, pinned) = screen.root.map { extractPinned($0) } ?? (nil, [])

        // Footer treatment: 'bar' (default) is a solid strip with a top
        // shadow; 'floating' lets the button float alone over the content.
        // One strip per screen — floating wins only when EVERY pinned button
        // asks for it.
        let floating = !pinned.isEmpty
            && pinned.allSatisfy { $0.props["pin_style"].stringValue == "floating" }

        ZStack {
            if let gradient = bgSpec?.swiftUIGradient {
                gradient.ignoresSafeArea()
            } else {
                backgroundColor.color.ignoresSafeArea()
            }
            // Full-bleed background asset, clipped to `height` fraction from
            // the top, edge-to-edge (bleeds under the status bar) + overlay.
            if screen.background["asset"].objectValue != nil {
                BackgroundLayer(background: screen.background, ctx: ctx)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                ChromeBar(
                    topBar: screen.topBar,
                    index: screenIndex,
                    total: flow.screens.count,
                    accent: ctx.color("primary", fallback: RGBAColor(hex: 0x16A34A)),
                    line: ctx.color("border", fallback: RGBAColor(hex: 0xE4E4E7)),
                    text: ctx.textSecondary,
                    // Paywall screens never show a back affordance — a user
                    // backing out of a purchase decision is a product rule.
                    canGoBack: canGoBack
                        && !noBackArchetypes.contains(screen.archetype ?? ""),
                    onAction: onAction)
                // The root tree may use a flex spacer to push a CTA to the
                // bottom. Wrap in a scroll view whose child is at least
                // viewport-tall so the spacer distributes when content fits,
                // and scrolls when it doesn't (fill-then-overflow parity).
                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        Group {
                            if let bodyRoot {
                                renderNode(bodyRoot, ctx)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                }
                if !pinned.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(pinned.enumerated()), id: \.offset) { _, node in
                            renderNode(node, ctx)
                        }
                    }
                    // Extraction loses the root stack's padding — reapply a
                    // standard content inset so the CTA doesn't touch edges.
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                    .background(
                        floating
                            ? AnyView(Color.clear)
                            // Mirrors the web sticky-CTA shadow (0 -8 16 -8 @12%).
                            : AnyView(backgroundColor.color.shadow(
                                color: Color.black.opacity(0.12),
                                radius: 8, x: 0, y: -4)))
                }
            }
        }
    }
}

/// Full-bleed background asset (image or a muted looping video) clipped to
/// `height` fraction from the top, with the optional overlay scrim over the
/// SAME area. Video falls back to a neutral surface under reduce-motion.
struct BackgroundLayer: View {
    let background: JSONValue
    let ctx: RenderCtx

    var body: some View {
        let asset = background["asset"]
        let kind = asset["kind"].stringValue ?? "image"
        let url = asset["url"].stringValue ?? ""
        let height = min(max(background["height"].doubleValue ?? 1, 0), 1)

        GeometryReader { proxy in
            layer(kind: kind, url: url)
                .frame(width: proxy.size.width, height: proxy.size.height * height)
                .clipped()
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func layer(kind: String, url: String) -> some View {
        let base: AnyView = {
            if kind == "image", !url.isEmpty, let imageURL = URL(string: url) {
                return AnyView(RemoteImage(url: imageURL, contentMode: .fill))
            }
            if kind == "video", !url.isEmpty, !ctx.reduceMotion,
               let videoURL = URL(string: url) {
                // Muted+loop+autoplay; transparent until the first frame.
                return AnyView(BackgroundVideoView(url: videoURL))
            }
            // video/lottie under reduce-motion, or no url: neutral surface.
            return AnyView(ctx.surface.color)
        }()

        if let overlay = background["overlay"].objectValue {
            let overlayJson = JSONValue.object(overlay)
            let color = ctx.color(
                overlayJson["color"].stringValue, fallback: .black)
            let opacity = min(max(overlayJson["opacity"].doubleValue ?? 0.4, 0), 1)
            ZStack {
                base
                // `opacity` MULTIPLIES the color's own alpha (web parity).
                color.opacity(color.a * opacity).color
            }
        } else {
            base
        }
    }
}

/// Top-bar chrome: progress indicator variants (dots / dashes / bar /
/// numbered / steps) centered, with a leading back chevron when the session
/// can go back, and trailing close (×) / skip affordances from `top_bar`.
struct ChromeBar: View {
    let topBar: JSONValue
    let index: Int
    let total: Int
    let accent: RGBAColor
    let line: RGBAColor
    let text: RGBAColor
    let canGoBack: Bool
    let onAction: ((String) -> Void)?

    var body: some View {
        let progress = topBar["progress"].stringValue
        let close = topBar["close"].boolValue == true
        let skipLabel = topBar["skip"]["label"].stringValue
        // Back shows only when the session can navigate back AND the screen
        // hasn't opted out via `top_bar.back = false`.
        let showBack = canGoBack && topBar["back"].boolValue != false
        let hasAffordance = showBack || close || (skipLabel?.isEmpty == false)
        let indicatorView = indicator(progress)

        if indicatorView == nil && !hasAffordance {
            Spacer().frame(height: 20)
        } else if !hasAffordance {
            // Indicator-only row keeps the compact metrics; the 44pt
            // tap-target bar is only paid for when affordances render.
            indicatorView
                .padding(EdgeInsets(top: 16, leading: 12, bottom: 8, trailing: 12))
        } else {
            ZStack {
                if let indicatorView {
                    indicatorView.padding(.horizontal, 56)
                }
                HStack {
                    if showBack {
                        chromeButton {
                            onAction?("back")
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(text.color)
                        }
                    }
                    Spacer(minLength: 0)
                    if close {
                        chromeButton {
                            onAction?("end:abandoned")
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(text.color)
                        }
                    } else if let skipLabel, !skipLabel.isEmpty {
                        chromeButton {
                            onAction?("next")
                        } label: {
                            Text(skipLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(text.color)
                        }
                    }
                }
            }
            .frame(height: 44)
        }
    }

    private func chromeButton<L: View>(
        action: @escaping () -> Void, @ViewBuilder label: () -> L
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func indicator(_ progress: String?) -> AnyView? {
        switch progress {
        case "dots", "dashes":
            let isDash = progress == "dashes"
            let count = min(total, 6)
            let idx = min(max(index, 0), count - 1)
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i <= idx ? accent.color : line.color)
                            .frame(width: isDash ? 16 : 6, height: isDash ? 3 : 6)
                    }
                }
                .frame(maxWidth: .infinity))
        case "bar":
            let fraction = Double(index + 1) / Double(total == 0 ? 1 : total)
            return AnyView(
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(line.color)
                        Capsule()
                            .fill(accent.color)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 4))
        case "numbered":
            return AnyView(
                Text("\(index + 1) / \(total)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(text.color)
                    .frame(maxWidth: .infinity))
        case "steps":
            // Segmented stepper — every screen gets a segment, filled up to
            // the current one (Duolingo / story style).
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(0..<max(total, 1), id: \.self) { i in
                        Capsule()
                            .fill(i <= index ? accent.color : line.color)
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                    }
                })
        default:
            return nil
        }
    }
}
