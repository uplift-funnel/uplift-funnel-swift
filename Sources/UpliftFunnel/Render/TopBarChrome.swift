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
/// `top_bar.progress` is NOT ported. Every screen in the corpus sets it to
/// `"none"` and expresses progress in the TREE instead — `behavior.step` on a
/// row of segments, which the solver lays out and the painter draws like
/// anything else. A second progress implementation up here would be a second
/// thing to keep in step with the first, so it waits for a document that
/// actually asks for it.
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
