import Foundation
import SwiftUI

// CSS string parsing shared by the primitive renderer, ported from the
// Flutter SDK's `css_style.dart`: colors (`#hex`, `rgb()`, `rgba()`),
// `linear-gradient(...)` backgrounds, and the `font_family` alias map. The
// dashboard authors these values as raw CSS, so this is the single
// Swift-side mirror of what the web renderer gets for free from the browser.

/// UI-framework-free color value (sRGB 0...1 channels) so parsing stays unit
/// testable from the CLI. Convert with `.color` at render time.
public struct RGBAColor: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(byteR: Int, byteG: Int, byteB: Int, byteA: Int = 255) {
        self.init(
            r: Double(byteR) / 255, g: Double(byteG) / 255,
            b: Double(byteB) / 255, a: Double(byteA) / 255)
    }

    /// 0xRRGGBB convenience (opaque) — mirrors Flutter's Color literals.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255,
            a: alpha)
    }

    public static let transparent = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)

    public var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public func opacity(_ alpha: Double) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: alpha)
    }

    /// Perceived-lightness test used for on-primary contrast.
    public var isLight: Bool {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}

private let rgbPattern = try! NSRegularExpression(
    pattern: #"^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+%?)\s*)?\)$"#,
    options: [.caseInsensitive])

/// Parses `#RGB` / `#RRGGBB` / `#RRGGBBAA` (schema byte order), `rgb(r,g,b)`
/// and `rgba(r,g,b,a)` (a as 0–1 float or percentage). Returns nil when the
/// input is not a recognizable color (e.g. a gradient or a token name).
public func parseCssColor(_ input: String) -> RGBAColor? {
    let raw = input.trimmingCharacters(in: .whitespaces)
    if raw.isEmpty { return nil }

    if raw.hasPrefix("#") || looksBareHex(raw) {
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        var alpha = 255
        if hex.count == 8 {
            // Schema form is RRGGBBAA.
            guard let a = Int(hex.suffix(2), radix: 16) else { return nil }
            alpha = a
            hex = String(hex.prefix(6))
        } else if hex.count != 6 {
            return nil
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return RGBAColor(
            byteR: Int((value >> 16) & 0xFF),
            byteG: Int((value >> 8) & 0xFF),
            byteB: Int(value & 0xFF),
            byteA: alpha)
    }

    let range = NSRange(raw.startIndex..., in: raw)
    if let m = rgbPattern.firstMatch(in: raw, range: range) {
        func group(_ i: Int) -> String? {
            guard m.range(at: i).location != NSNotFound,
                  let r = Range(m.range(at: i), in: raw) else { return nil }
            return String(raw[r])
        }
        func channel(_ s: String?) -> Int {
            Int(((Double(s ?? "") ?? 0).rounded()).clamped(to: 0...255))
        }
        let r = channel(group(1))
        let g = channel(group(2))
        let b = channel(group(3))
        var a = 255
        if let rawA = group(4) {
            let aVal: Double
            if rawA.hasSuffix("%") {
                aVal = ((Double(rawA.dropLast()) ?? 100) / 100)
            } else {
                aVal = Double(rawA) ?? 1
            }
            a = Int((aVal.clamped(to: 0...1) * 255).rounded())
        }
        return RGBAColor(byteR: r, byteG: g, byteB: b, byteA: a)
    }

    return nil
}

private func looksBareHex(_ s: String) -> Bool {
    (s.count == 3 || s.count == 6 || s.count == 8)
        && s.allSatisfy { $0.isHexDigit }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Backgrounds (solid | linear-gradient)

/// Result of parsing a CSS `background` value.
public enum CssBackground: Equatable, Sendable {
    case solid(RGBAColor)
    /// CSS convention: 0 = to top, 90 = to right, clockwise. `stops` are
    /// 0..1; nil = evenly spaced.
    case linearGradient(angleDeg: Double, colors: [RGBAColor], stops: [Double]?)

    /// Parses a solid color or a `linear-gradient(...)`. Nil when unparseable.
    public static func parse(_ input: String) -> CssBackground? {
        let raw = input.trimmingCharacters(in: .whitespaces)
        if raw.lowercased().hasPrefix("linear-gradient("), raw.hasSuffix(")") {
            let body = String(raw.dropFirst("linear-gradient(".count).dropLast())
            return parseLinearGradient(body)
        }
        return parseCssColor(raw).map { .solid($0) }
    }

    /// CSS angle → SwiftUI start/end points. The unit direction the gradient
    /// travels toward is d = (sin θ, -cos θ) in screen coords (y down); the
    /// alignment form is exact for square boxes and a close approximation
    /// otherwise — accepted parity tradeoff.
    public var swiftUIGradient: LinearGradient? {
        guard case .linearGradient(let angleDeg, let colors, let stops) = self else {
            return nil
        }
        let rad = angleDeg * .pi / 180
        let dx = sin(rad)
        let dy = -cos(rad)
        // Alignment(-dx,-dy)..(dx,dy) in [-1,1] space → UnitPoint [0,1].
        let start = UnitPoint(x: (1 - dx) / 2, y: (1 - dy) / 2)
        let end = UnitPoint(x: (1 + dx) / 2, y: (1 + dy) / 2)
        let gradientStops: [Gradient.Stop]
        if let stops {
            gradientStops = zip(colors, stops).map {
                Gradient.Stop(color: $0.color, location: $1)
            }
        } else {
            let n = max(colors.count - 1, 1)
            gradientStops = colors.enumerated().map {
                Gradient.Stop(color: $1.color, location: Double($0) / Double(n))
            }
        }
        return LinearGradient(
            gradient: Gradient(stops: gradientStops),
            startPoint: start, endPoint: end)
    }
}

private func parseLinearGradient(_ body: String) -> CssBackground? {
    let parts = splitTopLevel(body)
    if parts.isEmpty { return nil }

    var angle = 180.0  // CSS default: to bottom.
    var stopStart = 0

    let first = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
    if first.hasSuffix("deg"), let deg = Double(first.dropLast(3)) {
        angle = deg.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        stopStart = 1
    } else if first.hasPrefix("to ") {
        let keywords: [String: Double] = [
            "to top": 0, "to right": 90, "to bottom": 180, "to left": 270,
            "to top right": 45, "to right top": 45,
            "to bottom right": 135, "to right bottom": 135,
            "to bottom left": 225, "to left bottom": 225,
            "to top left": 315, "to left top": 315,
        ]
        let normalized = first
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let kw = keywords[normalized] else { return nil }
        angle = kw
        stopStart = 1
    }

    var colors: [RGBAColor] = []
    var positions: [Double?] = []
    for part in parts.dropFirst(stopStart) {
        let stop = part.trimmingCharacters(in: .whitespaces)
        if stop.isEmpty { return nil }
        // Split "<color> <pos>%" on the LAST space outside parens.
        var colorStr = stop
        var pos: Double?
        if let lastSpace = lastTopLevelSpaceIndex(stop) {
            let tail = String(stop[stop.index(after: lastSpace)...])
                .trimmingCharacters(in: .whitespaces)
            if tail.hasSuffix("%"), let p = Double(tail.dropLast()) {
                pos = (p / 100).clamped(to: 0...1)
                colorStr = String(stop[..<lastSpace])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let color = parseCssColor(colorStr) else { return nil }
        colors.append(color)
        positions.append(pos)
    }
    if colors.count < 2 { return nil }

    // Stops: all-nil → evenly spaced (nil). Otherwise fill gaps: first
    // defaults to 0, last to 1, interior nils interpolate linearly, and
    // values are forced non-decreasing.
    var stops: [Double]?
    if positions.contains(where: { $0 != nil }) {
        if positions[0] == nil { positions[0] = 0 }
        if positions[positions.count - 1] == nil { positions[positions.count - 1] = 1 }
        var i = 0
        while i < positions.count {
            if positions[i] != nil {
                i += 1
                continue
            }
            var j = i
            while positions[j] == nil { j += 1 }
            let prev = positions[i - 1]!
            let next = positions[j]!
            let gap = Double(j - (i - 1))
            for k in i..<j {
                positions[k] = prev + (next - prev) * Double(k - (i - 1)) / gap
            }
            i = j
        }
        var running = 0.0
        stops = positions.map { p in
            running = max(running, p!)
            return running
        }
    }

    return .linearGradient(angleDeg: angle, colors: colors, stops: stops)
}

/// Splits on commas that sit outside parentheses.
private func splitTopLevel(_ s: String) -> [String] {
    var out: [String] = []
    var depth = 0
    var current = ""
    for c in s {
        if c == "(" { depth += 1 }
        if c == ")" { depth -= 1 }
        if c == ",", depth == 0 {
            out.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    out.append(current)
    return out
}

private func lastTopLevelSpaceIndex(_ s: String) -> String.Index? {
    var depth = 0
    var index = s.endIndex
    while index > s.startIndex {
        index = s.index(before: index)
        let c = s[index]
        if c == ")" { depth += 1 }
        if c == "(" { depth -= 1 }
        if c == " ", depth == 0 { return index }
    }
    return nil
}

/// One flat color standing in for any parseable background — for surfaces
/// that cannot paint a gradient. Gradients yield their first stop, or the
/// last when `last` is set (e.g. a footer hugging the bottom of the screen).
public func representativeColor(_ input: String, last: Bool = false) -> RGBAColor? {
    switch CssBackground.parse(input) {
    case .solid(let color): return color
    case .linearGradient(_, let colors, _): return last ? colors.last : colors.first
    case nil: return nil
    }
}

// MARK: - font_family aliases

public enum ResolvedFontFamily: Equatable, Sendable {
    /// Platform default (`system` / `sans` / `display` / nil).
    case system
    /// Generic serif — rendered with the system serif design.
    case serif
    /// Generic monospace — rendered with the system monospaced design.
    case mono
    /// Verbatim family name — resolves iff the host app bundles/registers a
    /// font by that name, else the OS silently falls back to system.
    case custom(String)
}

/// Maps schema `font_family` aliases to a concrete family choice.
public func resolveFontFamilyAlias(_ raw: String?) -> ResolvedFontFamily {
    switch raw {
    case nil, "system", "sans", "display":
        return .system
    case "serif":
        return .serif
    case "mono":
        return .mono
    case .some(let name):
        return .custom(name)
    }
}
