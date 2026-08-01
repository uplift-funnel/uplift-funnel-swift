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
    var onSkip: () -> Void = {}

    /// How much room the chrome takes, for a bar that may hold nothing.
    ///
    /// A LITERAL 44 until now, which put every screen without a back or close
    /// button 24pt lower on the device than in the preview — and made the body
    /// 24pt shorter, so a `fill` child and a pinned footer both landed wrong.
    /// The web has always reserved 20 for an empty bar; this is the same rule,
    /// and the two are held to it by a test rather than by both being read.
    static func height(for bar: [String: Any]?, canGoBack: Bool) -> Double {
        affordance(in: bar, canGoBack: canGoBack) ? 44 : 20
    }

    /// Whether anything is actually drawn in the bar.
    static func affordance(in bar: [String: Any]?, canGoBack: Bool) -> Bool {
        let backHidden = (bar?["back"] as? Bool) == false
        return (canGoBack && !backHidden)
            || (bar?["close"] as? Bool) == true
            || (bar?["skip"] as? [String: Any])?["label"] is String
            || bar?["title"] is String
    }

    /// Shown whenever the session CAN go back, unless the screen opts out.
    ///
    /// It used to require an explicit `back: true`, so a flow that said nothing
    /// got a back button in the preview and none on the device — the opposite
    /// default, on the one control every multi-screen flow relies on.
    private var showBack: Bool {
        canGoBack && (topBar?["back"] as? Bool) != false
    }

    private var showClose: Bool {
        (topBar?["close"] as? Bool) == true
    }

    private var skipLabel: String? {
        (topBar?["skip"] as? [String: Any])?["label"] as? String
    }

    private var title: String? {
        topBar?["title"] as? String
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
        if Self.affordance(in: topBar, canGoBack: canGoBack) {
            ZStack {
                if let title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(tint)
                        .lineLimit(1)
                        // Clear of both controls, so a long title truncates
                        // rather than sliding under the chevron.
                        .padding(.horizontal, 56)
                }
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
                    } else if let skipLabel {
                        // Skip takes the DEFAULT transition, which is what the
                        // web fires too — not a dismissal.
                        button(skipLabel, size: 14, action: onSkip)
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 8)
        } else {
            // Reserved even when empty, so the body starts in the same place
            // whether or not a screen offers a way back.
            Color.clear.frame(height: 20)
        }
    }

    /// A glyph control, in a translucent disc.
    ///
    /// A bare chevron in the muted text colour disappears the moment a screen
    /// opens on a photograph or a dark gradient, which is most of the gallery,
    /// and it reads as chrome from a previous decade beside screens that draw
    /// their own round close button. The disc is neutral-translucent, so it
    /// darkens a light background and lightens a dark one without being told
    /// which it is. A skip LABEL keeps the bare treatment: a pill around a word
    /// competes with the screen's own buttons.
    private func button(
        _ glyph: String,
        size: Double? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: size ?? glyphSize, weight: size == nil ? .regular : .medium))
                .foregroundColor(tint)
                .modifier(GlyphDisc(enabled: size == nil))
                // A 44pt target, which is the platform minimum and bigger than
                // the glyph. A skip label needs its own width.
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, size == nil ? 0 : 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The disc behind a chrome glyph — see `button(_:size:action:)`.
private struct GlyphDisc: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.gray.opacity(0.18)))
        } else {
            content
        }
    }
}
