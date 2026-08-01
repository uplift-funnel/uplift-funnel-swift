import Combine
import CoreGraphics
import SwiftUI
import UpliftLayout

/// One v3 screen: everything drawn once, native controls laid over the top.
///
/// The shape of this is the architecture's whole payoff. There is no view per
/// node and no SwiftUI layout pass, so nothing can disagree with the solver —
/// the frames were checked against Chromium node by node and they are drawn
/// exactly where they were computed. What SwiftUI still does is the two things
/// only it can: raise a keyboard and run a gesture.
///
/// Native controls are OVERLAID rather than drawn because a drawn text field is
/// a lie — no caret, no selection, no dictation, no autofill, no accessibility.
/// The canvas skips their content so the two never double-draw.
struct PrimitiveScreenV3: View {
    let flow: [String: Any]
    let screenIndex: Int
    let locale: String?
    let products: [String: [String: String]]
    let size: CGSize
    let safeTop: Double
    /// Identity of the document, for the model cache — the flow itself is
    /// `[String: Any]` and cannot be hashed.
    let flowVersion: String

    /// The answers so far. Owned by the host, because navigating away and back
    /// must not lose them.
    @Binding var answers: [String: String]
    var images: [String: CGImage] = [:]
    var onAction: (String) -> Void = { _ in }

    /// Which field the keyboard is in, so only one overlay is focusable.
    @FocusState private var focused: String?

    /// Survives body evaluations; see `ScreenModelCache`.
    @State private var cache = ScreenModelCache()

    /// The clock a `behavior.countdown` counts against, in epoch milliseconds.
    ///
    /// Held here rather than read inside the decoder, so the decoder stays a
    /// pure function of its arguments and the same document laid out twice
    /// gives the same frames. Zero until the screen appears, which is what
    /// makes a countdown show its full length before the first tick instead of
    /// flashing a deadline long past.
    @State private var clock = (now: 0.0, entered: 0.0)

    /// Only a screen that carries one pays for a timer.
    private var ticks: Bool {
        cache.hasCountdown(screenIndex: screenIndex) {
            Self.carriesCountdown(screen(at: screenIndex)?["root"])
        }
    }

    /// Four times a second, not once: a 1s timer drifts against the wall clock
    /// and visibly skips a digit. `Empty` for a screen with no countdown — the
    /// publisher is never created, so nothing is scheduled.
    private var tick: AnyPublisher<Date, Never> {
        ticks
            ? Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
            : Empty<Date, Never>().eraseToAnyPublisher()
    }

    private var input: LayoutInput {
        // `__stepIndex` rides in with the variables because that is the channel
        // the decoder has: it decides completed/current/upcoming for every node
        // carrying `behavior.step`. Without it every screen decodes as step
        // zero — one lit segment, all the way through a funnel.
        var variables = answers
        if let step = LayoutDecoder.stepIndex(flow: flow, screenIndex: screenIndex) {
            variables["__stepIndex"] = String(step)
        }
        return LayoutInput(
            selections: answers,
            variables: variables,
            products: products,
            now: clock.now,
            screenEnteredAt: clock.entered
        )
    }

    private func screen(at index: Int) -> [String: Any]? {
        (flow["screens"] as? [[String: Any]])?.indices.contains(index) == true
            ? (flow["screens"] as? [[String: Any]])?[index]
            : nil
    }

    /// Does any node in this raw subtree carry `behavior.countdown`?
    ///
    /// Raw JSON rather than a decoded tree, because the answer is needed BEFORE
    /// the decode — the decode takes the clock as an input, and the clock only
    /// runs if the answer is yes.
    private static func carriesCountdown(_ node: Any?) -> Bool {
        guard let node = node as? [String: Any] else { return false }
        if (node["behavior"] as? [String: Any])?["countdown"] != nil { return true }
        guard let children = node["children"] as? [Any] else { return false }
        return children.contains { carriesCountdown($0) }
    }

    /// The screen, rebuilt whenever an answer changes.
    ///
    /// Rebuilding the WHOLE thing rather than patching it is deliberate: a
    /// selection changes a state, a state changes a delta, a delta can change a
    /// size, and a size moves every sibling below it. There is no such thing as
    /// a local update in a layout engine, and pretending otherwise is how
    /// renderers grow bugs that only appear on the third tap.
    ///
    /// So it is built once and reused until something it depends on moves,
    /// rather than being cheap enough to repeat.
    private var model: ScreenModel? {
        cache.model(for: ScreenModelKey(
            flowVersion: flowVersion,
            screenIndex: screenIndex,
            locale: locale,
            answers: answers,
            products: products,
            width: size.width,
            height: size.height,
            safeTop: safeTop,
            clockSecond: ticks ? Int(clock.now / 1000) : 0
        )) {
            let input = input
            guard let tree = LayoutDecoder.layoutTree(
                flow: flow, screenIndex: screenIndex, locale: locale, input: input
            ) else { return nil }
            guard let list = try? ScreenRenderer().displayList(
                flow: flow, screenIndex: screenIndex, locale: locale, input: input,
                viewport: Viewport(
                    size: Size2D(width: size.width, height: size.height), safeTop: safeTop
                )
            ) else { return nil }
            let interactions = LayoutDecoder.interactions(
                flow: flow, screenIndex: screenIndex, locale: locale, input: input
            )
            let scrollers = ScrollGeometry.scrollers(
                root: tree,
                frames: list.items.map { SolvedFrame(path: $0.path, rect: $0.frame) }
            )
            let rootScroll = scrollers.first { $0.path == "" && $0.scrolls }
            // How far the screen reaches above the body it was given.
            //
            // Read from the FRAMES rather than from the root scroller, so a
            // screen that bleeds without scrolling — a hero on a short screen —
            // still gets its room. It is the same number when both exist.
            let lift = max(0, -(list.items.filter { $0.scroller != nil || $0.path == "" }
                .map(\.frame.y).min() ?? 0))
            // Shifted ONCE, here, so everything downstream shares one set of
            // coordinates: the canvas paints them, `hitTest` answers in them,
            // and the native overlays are positioned at them.
            let (background, shifted) = list.translated(dy: lift).hoistingRootFill()

            let fields = interactions.targets.values
                .compactMap { target -> (target: TapTarget, item: PaintItem)? in
                    guard target.input != nil, let item = shifted.item(at: target.path) else {
                        return nil
                    }
                    return (target, item)
                }
                .sorted { $0.item.path < $1.item.path }
            // Split by which canvas an item belongs to. `scroller` was
            // resolved when the list was built, including the CSS rule that a
            // fixed node escapes its ancestors' overflow entirely.
            let pinnedItems = shifted.items.filter { $0.scroller == nil && $0.path != "" }
            let scrollingItems = shifted.items.filter { $0.scroller != nil || $0.path == "" }

            return ScreenModel(
                list: shifted,
                interactions: interactions,
                rootScroll: rootScroll,
                lift: lift,
                background: background,
                scrolling: DisplayList(
                    size: rootScroll?.content.size ?? list.size, items: scrollingItems
                ),
                pinned: DisplayList(
                    size: Size2D(width: list.size.width, height: list.size.height + lift),
                    items: pinnedItems
                ),
                fields: fields
            )
        }
    }

    /// The box actually drawn into: the body, plus whatever bleeds above it.
    private var drawnHeight: Double { size.height + (model?.lift ?? 0) }

    var body: some View {
        if let model {
            ZStack(alignment: .topLeading) {
                // The screen's own background, before anything else and past
                // every inset: `safeTop` here is the whole band above the body
                // — the status bar AND the chrome row — so a gradient reaches
                // the top of the display instead of starting under the back
                // button. Drawn with the engine rather than translated into
                // SwiftUI, so a linear, a radial and an image all arrive the
                // way the painter already knows how to draw them.
                if let background = model.background {
                    PrimitiveCanvas(
                        list: DisplayList(
                            size: Size2D(width: size.width, height: drawnHeight + safeTop),
                            items: [PaintItem(
                                path: "__background",
                                frame: Rect(
                                    x: 0, y: 0,
                                    width: size.width, height: drawnHeight + safeTop
                                ),
                                style: background
                            )]
                        ),
                        painter: FramePainter(images: images),
                        size: Size2D(width: size.width, height: drawnHeight + safeTop),
                        // Paint only: a background that answered taps would take
                        // them from the content sitting on it.
                        hittable: [],
                        onTap: { _ in }
                    )
                    .frame(width: size.width, height: drawnHeight + safeTop)
                    .padding(.top, -safeTop)
                    .allowsHitTesting(false)
                }
                if let scroll = model.rootScroll {
                    ScrollView(scroll.axis == .vertical ? .vertical : .horizontal) {
                        body(of: model, size: scroll.content.size)
                    }
                    // TALLER than the body by the lift, so the scroller's top
                    // edge is where the lifted content starts and its bottom
                    // edge is still the body's. Sized to the body alone, the
                    // scroll view cropped exactly the band the hero was
                    // reaching into, and no frame was wrong anywhere.
                    .frame(width: size.width, height: drawnHeight)
                } else {
                    body(of: model, size: Size2D(width: size.width, height: drawnHeight))
                }

                // Over the scroll view, so a pinned footer stays put while the
                // body moves under it. Omitted entirely when nothing is pinned
                // — an empty canvas is still a view, and one covering the
                // screen would take gestures from the thing behind it.
                if !model.pinned.items.isEmpty {
                    PrimitiveCanvas(
                        list: model.pinned,
                        painter: FramePainter(images: images),
                        size: Size2D(width: size.width, height: drawnHeight),
                        hittable: Set(model.pinned.items.map(\.path)),
                        onTap: { path in tap(path, with: model) }
                    )
                }
            }
            // The view REACHES UP by the lift and takes back the same amount
            // from its layout box, so the host's stack still hands it exactly
            // the body it computed. A negative padding rather than an offset,
            // because an offset does not move a view's hit region out of the
            // slot it was given and the top of a bleeding hero would not be
            // tappable.
            .frame(width: size.width, height: drawnHeight, alignment: .topLeading)
            .padding(.top, -(model.lift))
            .onAppear {
                // `duration_ms` counts from screen entry, so "when this
                // appeared" is exactly the number wanted — and reading it here
                // rather than in an initializer keeps a screen that is never
                // shown from starting its clock.
                guard ticks, clock.entered == 0 else { return }
                let now = Date().timeIntervalSince1970 * 1000
                clock = (now: now, entered: now)
            }
            .onReceive(tick) { date in
                clock.now = date.timeIntervalSince1970 * 1000
            }
        } else {
            // A screen that will not lay out is a bug worth seeing, not a blank
            // the user silently stares at.
            Color.clear.overlay(Text("layout failed").font(.footnote).foregroundColor(.secondary))
        }
    }

    /// The scrolling body: the canvas plus the native fields that ride with it.
    ///
    /// The fields go INSIDE the scroll content rather than over it. Their
    /// `.position` arithmetic is unchanged, because content coordinates are the
    /// solver's coordinates — the content origin is clamped to the scroller's
    /// own start — so no scroll offset ever has to be applied to them. It also
    /// means SwiftUI's own scroll-to-focus works: tap a field near the bottom
    /// and the keyboard no longer covers it.
    private func body(of model: ScreenModel, size: Size2D) -> some View {
        ZStack(alignment: .topLeading) {
            PrimitiveCanvas(
                // The fields' own text is drawn by the overlay below.
                list: model.scrolling.withoutContent(at: Set(model.fields.map(\.item.path))),
                painter: FramePainter(images: images),
                size: size,
                onTap: { path in tap(path, with: model) }
            )
            ForEach(model.fields, id: \.item.path) { field in
                overlay(for: field.target, item: field.item)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - touch

    private func tap(_ path: String, with model: ScreenModel) {
        // The map is read from the model rather than recomputed. It used to be
        // a computed property touched three times here — handler, answers,
        // auto-advance — which was three full document walks per tap.
        let interactions = model.interactions
        guard let target = interactions.handler(for: path) else { return }

        if let input = target.input {
            focused = input.saveTo
            return
        }
        if let select = target.select {
            answers = interactions.answers(applying: select, to: answers)
            if let title = select.title {
                answers["\(select.group).title"] = title
            }
            if interactions.autoAdvances(select) {
                onAction("next")
                return
            }
        }
        for action in target.actions { onAction(action) }
    }

    // MARK: - native controls

    @ViewBuilder
    private func overlay(for target: TapTarget, item: PaintItem) -> some View {
        if let input = target.input {
            let box = item.contentBox
            Group {
                if input.secure {
                    SecureField(input.placeholder ?? "", text: binding(input.saveTo))
                } else {
                    TextField(input.placeholder ?? "", text: binding(input.saveTo))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .autocorrectionDisabled(input.kind == "email")
            .focused($focused, equals: input.saveTo)
            .modifier(KeyboardKind(kind: input.kind))
            .frame(width: box.width, height: box.height)
            .position(x: box.x + box.width / 2, y: box.y + box.height / 2)
        }
    }

    /// Writes go through the same `answers` the layout reads, so a keystroke
    /// re-solves the screen — which is what makes a field redden the moment it
    /// is emptied rather than on the next tap.
    private func binding(_ saveTo: String) -> Binding<String> {
        Binding(
            get: { answers[saveTo] ?? "" },
            set: { answers[saveTo] = $0 }
        )
    }

}

/// The keyboard an input kind raises.
///
/// Its own modifier because `UIKeyboardType` is UIKit's and this package builds
/// for macOS as well — the layout core is asserted in a plain `swift test`
/// process, so anything iOS-only has to be behind a wall rather than assumed.
private struct KeyboardKind: ViewModifier {
    let kind: String

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        switch kind {
        case "number":
            content.keyboardType(.numberPad)
        case "email":
            content.keyboardType(.emailAddress).textContentType(.emailAddress)
        case "phone":
            content.keyboardType(.phonePad).textContentType(.telephoneNumber)
        default:
            content
        }
        #else
        content
        #endif
    }
}
