import SwiftUI
import UpliftLayout

/// The screen's chrome: back, close, and nothing else yet.
///
/// Chrome rather than content, and that is a real distinction here — `top_bar`
/// sits beside `root` in the document, not inside it, so the solver never sees
/// it and it holds no frame. It is drawn as SwiftUI because it is two buttons
/// and a fixed height, and because a back chevron wants a real hit target and
/// a real pressed state rather than a painted one.
///
/// There is no progress indicator here, and there is no `top_bar.progress` any
/// more either. It could not be laid out: the body's box has to be derived
/// before anything is on screen, and an indicator row's height depends on the
/// indicator — one style being literally "1 / 5", whose height is a text
/// measurement. So the web preview returned no height for such a bar and fell
/// back to CSS layout, meaning a decorative property decided which LAYOUT
/// ENGINE ran, and the preview stopped matching this one.
///
/// Progress is expressed in the TREE instead — `behavior.step` on a row of
/// boxes, which the solver lays out and the painter draws like anything else,
/// so all three platforms agree about it for free.
struct TopBarChrome: View {
    let topBar: [String: Any]?
    let palette: [String: String]
    let canGoBack: Bool
    var onBack: () -> Void
    var onClose: () -> Void

    /// Matches the web's chrome bar so the two agree about how much room the
    /// body starts with.
    static let height: Double = 44

    private var showBack: Bool {
        (topBar?["back"] as? Bool) == true && canGoBack
    }

    private var showClose: Bool {
        (topBar?["close"] as? Bool) == true
    }

    private var tint: Color {
        let raw = (topBar?["controls"] as? [String: Any])?["color"] as? String
        return Color(
            RGBA.parse(raw, tokens: palette)
                ?? RGBA.parse("text_primary", tokens: palette)
                ?? .black
        )
    }

    private var glyphSize: Double {
        ((topBar?["controls"] as? [String: Any])?["size"] as? NSNumber)?.doubleValue ?? 20
    }

    var body: some View {
        HStack(spacing: 0) {
            if showBack {
                button(
                    (topBar?["controls"] as? [String: Any])?["back_icon"] as? String ?? "‹",
                    action: onBack
                )
                .accessibilityLabel("Back")
            }
            Spacer(minLength: 0)
            if showClose {
                button(
                    (topBar?["controls"] as? [String: Any])?["close_icon"] as? String ?? "✕",
                    action: onClose
                )
                .accessibilityLabel("Close")
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 8)
        // Always present, even with nothing in it: the body's top has to be in
        // the same place whether or not a screen offers a way back, or every
        // screen in a flow starts at a different height.
    }

    private func button(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: glyphSize))
                .foregroundColor(tint)
                // A 44pt target, which is the platform minimum and bigger than
                // the glyph.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
