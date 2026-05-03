import SwiftUI

/// Resolves Funnel theme tokens to SwiftUI colors. Falls back to a neutral
/// default palette when the flow ships without a theme.

public struct ResolvedTheme: Sendable {
    public let primary: Color
    public let accent: Color
    public let background: Color
    public let surface: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let border: Color
    public let cornerRadius: CGFloat

    public static let fallback = ResolvedTheme(
        primary: Color(red: 0.0, green: 0.4, blue: 1.0),
        accent: Color(red: 0.3, green: 0.5, blue: 0.95),
        background: Color(red: 0.97, green: 0.97, blue: 0.97),
        surface: .white,
        textPrimary: Color(red: 0.1, green: 0.1, blue: 0.1),
        textSecondary: Color(red: 0.42, green: 0.42, blue: 0.5),
        border: Color(red: 0.91, green: 0.91, blue: 0.93),
        cornerRadius: 12
    )

    public static func resolve(_ theme: Theme?) -> ResolvedTheme {
        guard let theme else { return .fallback }
        let c = theme.tokens.colors
        return ResolvedTheme(
            primary: hex(c.primary),
            accent: c.accent.flatMap(hex) ?? hex(c.primary),
            background: hex(c.background),
            surface: hex(c.surface),
            textPrimary: hex(c.textPrimary),
            textSecondary: hex(c.textSecondary),
            border: c.border.flatMap(hex) ?? Color.gray.opacity(0.2),
            cornerRadius: 16
        )
    }
}

/// Hex parser. Accepts #RGB / #RRGGBB / #RRGGBBAA. Falls back to clear.
public func hex(_ raw: String) -> Color {
    var s = raw
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 {
        s = s.map { "\($0)\($0)" }.joined()
    }
    var alpha: Double = 1.0
    if s.count == 8 {
        let aStr = String(s.suffix(2))
        s = String(s.prefix(6))
        if let a = UInt8(aStr, radix: 16) { alpha = Double(a) / 255.0 }
    }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return .clear }
    let r = Double((v >> 16) & 0xFF) / 255.0
    let g = Double((v >> 8) & 0xFF) / 255.0
    let b = Double(v & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b, opacity: alpha)
}

struct PrimaryButtonStyle: ButtonStyle {
    let theme: ResolvedTheme
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill(enabled ? theme.primary : theme.primary.opacity(0.4))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ThemeKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = .fallback
}

extension EnvironmentValues {
    var funnelTheme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
