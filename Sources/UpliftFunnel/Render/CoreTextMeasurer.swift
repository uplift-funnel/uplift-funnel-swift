import CoreText
import Foundation
import UpliftLayout

/// Shaping text the way the browser did, so the solver's frames survive contact
/// with a real font.
///
/// The layout engine asks a `TextMeasuring` how wide and how tall a run is, and
/// against the recorded baseline it gets Chromium's own answers. On a device it
/// gets these, and every difference between the two moves a frame — so this file
/// is held to the same numbers the solver is, and tested separately from it, so
/// that a parity failure says which of the two is at fault.
///
/// Two decisions here are the whole difference between matching and not.
public struct CoreTextMeasurer: TextMeasuring {
    public init() {}

    // MARK: - the font

    /// The system font at a CSS weight, driven through SF's variable axis.
    ///
    /// NOT `UIFont.systemFont(ofSize:weight:)`. That snaps to SF's named
    /// instances, which do not sit at the CSS weight positions: measured
    /// against Chromium on a 26pt heading, the named instances are +0.88pt out
    /// at CSS 500, +5.30 at 800 and +8.86 at 900. Driving the `wght` axis
    /// directly lands within 0.036pt across the whole 100–900 range. The corpus
    /// hits this on every `subtitle` and `label`, which the type ramp puts at
    /// `medium`.
    static func font(size: Double, weight: Int) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
        // 'wght' as a four-character code, which is how the axis is identified.
        let axis = 0x77676874 as CFNumber
        let descriptor = CTFontCopyFontDescriptor(base)
        let varied = CTFontDescriptorCreateCopyWithVariation(
            descriptor, axis, CGFloat(weight)
        )
        return CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateCopyWithAttributes(varied, [
                kCTFontCascadeListAttribute: emojiFirstCascade(for: base),
            ] as CFDictionary),
            CGFloat(size),
            nil
        )
    }

    /// The system's own fallback chain, with the untracked emoji face in front.
    ///
    /// Left alone, the system font falls back to `.AppleColorEmojiUI` — the
    /// variant tuned for UI labels, which pads every emoji: measured against the
    /// browser it is 3pt wide at 18pt and 4pt at 34pt, on an element whose whole
    /// width IS the glyph. That is not rounding; it is tracking that the browser
    /// does not apply, because Blink names the family `Apple Color Emoji` and
    /// gets the plain face.
    ///
    /// Naming it here the way the browser does closes it to at most a point.
    /// The residue is not recoverable: `CTFontGetAdvancesForGlyphs` already
    /// returns whole numbers for this font — it is a bitmap face that quantises
    /// internally — so there is no finer value left to round Chromium's way.
    ///
    /// PREPENDED to the default list rather than replacing it. Replacing it
    /// strands every other fallback, and the corpus needs one immediately: the
    /// paywall's ✕ resolves to Zapf Dingbats, which is not in the system font
    /// and not an emoji.
    private static func emojiFirstCascade(for base: CTFont) -> CFArray {
        let plain = CTFontDescriptorCreateWithNameAndSize(
            "AppleColorEmoji" as CFString, 0
        )
        let existing = CTFontCopyDefaultCascadeListForLanguages(base, nil) as? [CTFontDescriptor]
        return ([plain] + (existing ?? [])) as CFArray
    }

    /// The run as one attributed string, spans and all.
    ///
    /// CoreText shapes mixed attributes natively, so the typesetter breaks
    /// ACROSS spans without any inline-layout code here: "€8.99 / week" is one
    /// paragraph whose first five characters are 22pt bold, and a break can land
    /// anywhere in it. Building a string per span and adding the widths would
    /// get the same answer only while the run fits on one line.
    private func attributed(_ run: TextRunSpec) -> NSAttributedString {
        let paragraph = paragraphStyle(run)
        let out = NSMutableAttributedString()
        for span in run.resolvedSpans {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: Self.font(size: span.fontSize, weight: span.fontWeight),
            ]
            if span.letterSpacing != 0 { attrs[.kern] = span.letterSpacing }
            if let paragraph {
                attrs[kCTParagraphStyleAttributeName as NSAttributedString.Key] = paragraph
            }
            out.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return out
    }

    /// A fixed line box, matching CSS.
    ///
    /// The browser resolves `line-height` into a number of points and every line
    /// gets exactly that, so min and max are set to the same value and the
    /// font's own leading is ignored. The value is quantised because Chromium
    /// quantises per line and then sums — over ten lines the difference is an
    /// eighth of a point.
    ///
    /// The height comes from `lineBox`, which is the TALLEST inline box on the
    /// line rather than the node's own: a price node struts at the 16pt body
    /// ramp and is out-voted by its 22pt spans, giving 31.9 where the node alone
    /// would say 23.2.
    private func paragraphStyle(_ run: TextRunSpec) -> CTParagraphStyle? {
        guard run.lineHeight != nil || run.spans?.contains(where: { $0.lineHeight != nil }) == true
        else { return nil }
        // CoreText's own paragraph style, not `NSMutableParagraphStyle`: that
        // lives in UIKit on iOS and AppKit on macOS, and this package builds for
        // both plus a plain `swift test` process.
        var h = CGFloat(run.lineBox)
        let settings = withUnsafeBytes(of: &h) { raw -> [CTParagraphStyleSetting] in
            let p = raw.baseAddress!
            return [
                CTParagraphStyleSetting(
                    spec: .minimumLineHeight,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: p
                ),
                CTParagraphStyleSetting(
                    spec: .maximumLineHeight,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: p
                ),
            ]
        }
        return CTParagraphStyleCreate(settings, settings.count)
    }

    // MARK: - measuring

    public func measure(_ run: TextRunSpec) -> TextMetrics {
        guard !run.text.isEmpty else { return TextMetrics(lines: [], width: 0, height: 0) }
        let attributed = self.attributed(run)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        let limit = run.maxWidth.map { max(0, $0) } ?? .greatestFiniteMagnitude

        var lines: [TextLine] = []
        var start = 0
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, limit)
            if count <= 0 {
                // A single word wider than the box. CSS still puts it on its
                // own line and lets it overflow rather than dropping it, so a
                // cluster break keeps forward progress instead of looping.
                count = CTTypesetterSuggestClusterBreak(typesetter, start, limit)
                if count <= 0 { count = 1 }
            }
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(typesetter, range)
            let text = (attributed.string as NSString).substring(
                with: NSRange(location: start, length: count)
            )
            lines.append(TextLine(text: text, width: width(of: line)))
            start += count
        }

        let perLine = run.lineHeight == nil && run.spans == nil
            ? lineHeight(of: attributed)
            : run.lineBox
        return TextMetrics(
            lines: lines,
            width: lines.map(\.width).max() ?? 0,
            height: perLine * Double(lines.count)
        )
    }

    /// The run on one unbroken line — what CSS calls max-content, and what the
    /// browser sizes a hugging text element by.
    public func minContentWidth(_ run: TextRunSpec) -> Double {
        // The longest single word: a box cannot be squeezed narrower than this
        // without overflowing, which is the floor a row's shrink respects.
        //
        // Words are taken WITHIN a span, not across the joined string. A word
        // straddling a span boundary would be measured in two fonts, and CSS
        // has no such word anyway — an inline box boundary is not a break
        // opportunity, but neither is it a place a word's glyphs change size
        // mid-syllable in any document worth laying out.
        run.resolvedSpans.flatMap { span in
            span.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { word in
                var single = run
                single.spans = nil
                single.text = String(word)
                single.fontSize = span.fontSize
                single.fontWeight = span.fontWeight
                single.letterSpacing = span.letterSpacing
                single.maxWidth = nil
                return maxContentWidth(single)
            }
        }.max() ?? 0
    }

    /// The width of the whole run laid on one line, trailing space excluded.
    public func maxContentWidth(_ run: TextRunSpec) -> Double {
        guard !run.text.isEmpty else { return 0 }
        return width(of: CTLineCreateWithAttributedString(attributed(run)))
    }

    // MARK: - the two corrections

    /// A line's advance width, minus the space hanging off its end.
    ///
    /// `CTLineGetTypographicBounds` includes the trailing whitespace; CSS
    /// collapses it, so it contributes nothing to the line box. Left in, it is
    /// the entire per-line width difference against Chromium — measured at
    /// 4.18pt on a wrapped paragraph, which is far more than the sixty-fourth
    /// of a point the frames are held to.
    private func width(of line: CTLine) -> Double {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Double(advance - CTLineGetTrailingWhitespaceWidth(line))
    }

    private func lineHeight(of attributed: NSAttributedString) -> Double {
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return lu(Double(ascent + descent + leading))
    }
}
