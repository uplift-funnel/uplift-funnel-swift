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

    /// The answers so far. Owned by the host, because navigating away and back
    /// must not lose them.
    @Binding var answers: [String: String]
    var images: [String: CGImage] = [:]
    var onAction: (String) -> Void = { _ in }

    /// Which field the keyboard is in, so only one overlay is focusable.
    @FocusState private var focused: String?

    private var input: LayoutInput {
        LayoutInput(selections: answers, variables: answers, products: products)
    }

    private var interactions: InteractionMap {
        LayoutDecoder.interactions(flow: flow, screenIndex: screenIndex, locale: locale, input: input)
    }

    /// The screen, rebuilt whenever an answer changes.
    ///
    /// Rebuilding the WHOLE list rather than patching it is deliberate: a
    /// selection changes a state, a state changes a delta, a delta can change a
    /// size, and a size moves every sibling below it. There is no such thing as
    /// a local update in a layout engine, and pretending otherwise is how
    /// renderers grow bugs that only appear on the third tap.
    private var list: DisplayList? {
        try? ScreenRenderer(images: images).displayList(
            flow: flow, screenIndex: screenIndex, locale: locale, input: input,
            viewport: Viewport(
                size: Size2D(width: size.width, height: size.height), safeTop: safeTop
            )
        )
    }

    /// Every input node's frame, for the overlays.
    private func fields(_ list: DisplayList) -> [(target: TapTarget, item: PaintItem)] {
        interactions.targets.values.compactMap { target in
            guard target.input != nil, let item = list.item(at: target.path) else { return nil }
            return (target, item)
        }
        // Sorted so the view identity is stable across rebuilds — an unordered
        // dictionary would reshuffle the overlays and drop the keyboard.
        .sorted { $0.item.path < $1.item.path }
    }

    var body: some View {
        if let list {
            ZStack(alignment: .topLeading) {
                PrimitiveCanvas(
                    // The fields' own text is drawn by the overlay below.
                    list: list.withoutContent(at: Set(fields(list).map(\.item.path))),
                    painter: FramePainter(images: images),
                    onTap: { path in tap(path, in: list) }
                )
                ForEach(fields(list), id: \.item.path) { field in
                    overlay(for: field.target, item: field.item)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            // A screen that will not lay out is a bug worth seeing, not a blank
            // the user silently stares at.
            Color.clear.overlay(Text("layout failed").font(.footnote).foregroundColor(.secondary))
        }
    }

    // MARK: - touch

    private func tap(_ path: String, in list: DisplayList) {
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
