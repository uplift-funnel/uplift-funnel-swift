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
/// Node types that can move the user forward on their own.
///
/// `choice` is conditional: a plain one waits for a CTA, an `auto_advance` one
/// navigates on tap. `progress` is deliberately absent — it's the node asking
/// this question.
private let kExitNodeTypes: Set<String> = ["button", "signin", "swipe", "plan_picker"]

/// Whether anything on this screen can advance it.
///
/// A screen whose only content is a loading indicator has exactly one sensible
/// reading, and answering "no" is what keeps it from hanging when the author
/// forgot `advance_on_complete`.
func screenHasExit(_ screen: PrimScreen) -> Bool {
    if screen.topBar["close"].boolValue == true { return true }
    if !screen.topBar["skip"].isNull { return true }

    // Nothing to reason about — stay conservative.
    guard let root = screen.root else { return true }

    func visit(_ node: PrimNode) -> Bool {
        if kExitNodeTypes.contains(node.type) { return true }
        if node.type == "choice", node.props["auto_advance"].boolValue == true {
            return true
        }
        return node.children.contains(where: visit)
    }
    return visit(root)
}

func findPlanSaveTo(_ node: PrimNode) -> String? {
    if node.type == "plan_picker" { return node.saveTo }
    for child in node.children {
        if let found = findPlanSaveTo(child) { return found }
    }
    return nil
}

/// Node types whose props carry `pin_bottom` (schema: the `Pinnable` mixin).
///
/// `signin` joined `button` because the `buttons_bottom` layout only puts a
/// flexible spacer above the provider buttons, which stops holding them down
/// the moment the content outgrows the viewport.
private let pinnableTypes: Set<String> = ["button", "signin"]

/// Depth-first collects nodes with `props.pin_bottom == true` and returns the
/// tree without them. Carousel/swipe subtrees are left intact — a slide-local
/// CTA can't meaningfully pin to the screen.
func extractPinned(_ node: PrimNode) -> (kept: PrimNode?, pinned: [PrimNode]) {
    if pinnableTypes.contains(node.type), node.props["pin_bottom"].boolValue == true {
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
        // Lets a `progress` node know it is the only way off this screen.
        ctx.screenHasExit = screenHasExit(screen)

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
        // `progress` is a bare style name OR the object form; normalize once.
        // Mirrors progressIndicatorOf in @funnel/schema — the three renderers
        // must agree on what a bare string means.
        let spec = progressSpec
        let style = spec["style"].stringValue
        let close = topBar["close"].boolValue == true
        let skipLabel = topBar["skip"]["label"].stringValue
        let title = topBar["title"].stringValue
        // Back shows only when the session can navigate back AND the screen
        // hasn't opted out via `top_bar.back = false`.
        let showBack = canGoBack && topBar["back"].boolValue != false
        let hasAffordance =
            showBack || close || (skipLabel?.isEmpty == false) || (title?.isEmpty == false)

        let controls = topBar["controls"]
        let glyphColor = resolveColor(controls["color"].stringValue) ?? text
        let glyphSize = controls["size"].doubleValue
        let indicatorView = indicator(spec, style)
        // `below_bar` gives the indicator its own line under the affordance
        // row, which is what a titled app bar usually wants.
        let below = indicatorView != nil && spec["position"].stringValue == "below_bar"

        if indicatorView == nil && !hasAffordance {
            Spacer().frame(height: 20)
        } else if !hasAffordance {
            // Indicator-only row keeps the compact metrics; the 44pt
            // tap-target bar is only paid for when affordances render.
            indicatorView
                .padding(EdgeInsets(top: 16, leading: 12, bottom: 8, trailing: 12))
        } else {
            VStack(spacing: 0) {
                ZStack {
                    if let indicatorView, !below {
                        indicatorView.padding(.horizontal, 56)
                    } else if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(glyphColor.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 56)
                    }
                    HStack {
                        if showBack {
                            chromeButton {
                                onAction?("back")
                            } label: {
                                glyph(
                                    override: controls["back_icon"].stringValue,
                                    systemName: "chevron.left",
                                    size: glyphSize ?? 16,
                                    weight: .semibold,
                                    color: glyphColor)
                            }
                        }
                        Spacer(minLength: 0)
                        if close {
                            chromeButton {
                                onAction?("end:abandoned")
                            } label: {
                                glyph(
                                    override: controls["close_icon"].stringValue,
                                    systemName: "xmark",
                                    size: glyphSize ?? 16,
                                    weight: .medium,
                                    color: glyphColor)
                            }
                        } else if let skipLabel, !skipLabel.isEmpty {
                            chromeButton {
                                onAction?("next")
                            } label: {
                                Text(skipLabel)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(glyphColor.color)
                            }
                        }
                    }
                }
                .frame(height: 44)
                if let indicatorView, below {
                    indicatorView
                        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                }
            }
        }
    }

    /// Normalizes `top_bar.progress` — a bare style name or the object form.
    private var progressSpec: JSONValue {
        let raw = topBar["progress"]
        if let style = raw.stringValue { return .object(["style": .string(style)]) }
        return raw
    }

    /// A theme token name or raw hex → a colour, or nil to inherit.
    private func resolveColor(_ ref: String?) -> RGBAColor? {
        guard let ref, !ref.isEmpty else { return nil }
        switch ref {
        case "primary", "accent": return accent
        case "border": return line
        case "text_primary", "text_secondary": return text
        default: return parseCssColor(ref)
        }
    }

    /// An author-supplied character, or the platform-standard SF Symbol.
    @ViewBuilder
    private func glyph(
        override: String?, systemName: String, size: Double, weight: Font.Weight,
        color: RGBAColor
    ) -> some View {
        if let override, !override.isEmpty {
            Text(override)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color.color)
        } else {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color.color)
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

    private func indicator(_ spec: JSONValue, _ style: String?) -> AnyView? {
        // Author overrides, falling back to what was hardcoded before.
        let fill = resolveColor(spec["color"].stringValue) ?? accent
        let track = resolveColor(spec["track_color"].stringValue) ?? line
        let thickness = spec["thickness"].doubleValue
        let maxMarkers = spec["max_markers"].intValue ?? 6
        // Derived from the screen's position unless the author said otherwise —
        // a branch or a resumed onboarding shows a slice, not the whole flow.
        let idxBase = spec["index_override"].intValue ?? index
        let tot = spec["total_override"].intValue ?? total

        switch style {
        case "dots", "dashes":
            let isDash = style == "dashes"
            let count = min(tot, maxMarkers)
            if count <= 0 { return nil }
            let idx = min(max(idxBase, 0), count - 1)
            let size = thickness ?? (isDash ? 3 : 6)
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i <= idx ? fill.color : track.color)
                            .frame(width: isDash ? 16 : size, height: size)
                    }
                }
                .frame(maxWidth: .infinity))
        case "bar":
            let fraction = Double(idxBase + 1) / Double(tot == 0 ? 1 : tot)
            return AnyView(
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(track.color)
                        Capsule()
                            .fill(fill.color)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: thickness ?? 4))
        case "numbered":
            return AnyView(
                Text("\(idxBase + 1) / \(tot)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    // `color` names the ACTIVE colour in every other style, so
                    // honouring it here keeps one meaning across all of them.
                    .foregroundColor((spec["color"].stringValue != nil ? fill : text).color)
                    .frame(maxWidth: .infinity))
        case "steps":
            // Segmented stepper — every screen gets a segment, filled up to
            // the current one (Duolingo / story style).
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(0..<max(tot, 1), id: \.self) { i in
                        Capsule()
                            .fill(i <= idxBase ? fill.color : track.color)
                            .frame(height: thickness ?? 4)
                            .frame(maxWidth: .infinity)
                    }
                })
        default:
            return nil
        }
    }
}
