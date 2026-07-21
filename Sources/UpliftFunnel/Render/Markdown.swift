import Foundation
import SwiftUI

// Minimal markdown-lite, ported from `content_nodes.dart`: `[label](href)`,
// `**bold**` and `*italic*`. Produces an AttributedString so bold/italic
// segments carry the right weight/style. Links render underlined and fire
// their action through the same `dispatchAction` path as buttons (via the
// `uplift-action:` URL scheme + an OpenURLAction installed by the screen
// view), so the two can never drift.

private let markdownPattern = try! NSRegularExpression(
    pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)|\*\*(.+?)\*\*|\*(.+?)\*"#)

private let bareActionPattern = try! NSRegularExpression(
    pattern: #"^(next|back|submit|select|purchase|restore)$"#)
private let prefixedActionPattern = try! NSRegularExpression(
    pattern: #"^(go|url|end):"#)

/// A markdown link `(href)` can drive any button-style action, not just
/// URLs — `[Restore](restore)` fires `restore`. A bare known verb or a
/// `go:`/`url:`/`end:` prefix passes through; everything else becomes
/// `url:<href>` so `https://…` links are unchanged.
func actionForHref(_ href: String) -> String {
    let range = NSRange(href.startIndex..., in: href)
    if bareActionPattern.firstMatch(in: href, range: range) != nil
        || prefixedActionPattern.firstMatch(in: href, range: range) != nil {
        return href
    }
    return "url:\(href)"
}

/// The custom URL scheme markdown action-links use to reach the screen's
/// OpenURLAction.
enum ActionLink {
    static let scheme = "uplift-action"

    static func url(for action: String) -> URL? {
        let encoded = action.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? action
        return URL(string: "\(scheme):\(encoded)")
    }

    static func action(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(scheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }
}

struct TextSpanStyle {
    var size: Double
    var weight: Font.Weight
    var color: RGBAColor
    var family: ResolvedFontFamily
    var italic: Bool = false
    var decoration: String?
    var letterSpacing: Double?

    var font: Font {
        primFont(family: family, size: size, weight: weight, italic: italic)
    }
}

/// Parses `input` into a styled AttributedString.
func markdownLite(_ input: String, base: TextSpanStyle) -> AttributedString {
    func styled(
        _ text: String, weight: Font.Weight? = nil, italic: Bool = false,
        link: String? = nil
    ) -> AttributedString {
        var run = AttributedString(text)
        var style = base
        if let weight { style.weight = weight }
        if italic { style.italic = true }
        run.font = style.font
        run.foregroundColor = style.color.color
        if let letterSpacing = base.letterSpacing { run.kern = letterSpacing }
        switch base.decoration {
        case "underline": run.underlineStyle = .single
        case "strike": run.strikethroughStyle = .single
        default: break
        }
        if let link, let url = ActionLink.url(for: actionForHref(link)) {
            run.link = url
            run.underlineStyle = .single
        }
        return run
    }

    guard input.contains("*") || input.contains("[") else {
        return styled(input)
    }

    var out = AttributedString()
    var last = input.startIndex
    let range = NSRange(input.startIndex..., in: input)
    for m in markdownPattern.matches(in: input, range: range) {
        guard let full = Range(m.range, in: input) else { continue }
        if full.lowerBound > last {
            out += styled(String(input[last..<full.lowerBound]))
        }
        func group(_ i: Int) -> String? {
            guard m.range(at: i).location != NSNotFound,
                  let r = Range(m.range(at: i), in: input) else { return nil }
            return String(input[r])
        }
        if let label = group(1), let href = group(2) {
            out += styled(label, link: href)
        } else if let bold = group(3) {
            out += styled(bold, weight: .bold)
        } else if let italic = group(4) {
            out += styled(italic, italic: true)
        }
        last = full.upperBound
    }
    if last < input.endIndex {
        out += styled(String(input[last...]))
    }
    return out
}
