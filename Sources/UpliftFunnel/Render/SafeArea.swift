import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The device's safe-area insets, read from the WINDOW.
///
/// `GeometryProxy.safeAreaInsets` reports zero inside a view that has already
/// said `.ignoresSafeArea()` — which is exactly where this renderer reads it,
/// because the whole point is that a hero can bleed under the status bar. So
/// the host padded the chrome by zero, the close button landed in the middle
/// of the status bar, and every screen sat 59pt too high. The `ignoreSafeArea`
/// nodes were wrong too, since the solver was told the inset was zero and had
/// nothing to lift them out of.
///
/// The window is the right source for a second reason: this renderer also runs
/// inside a Flutter `UiKitView`, where a `UIHostingController` hung off a plain
/// container view does not reliably inherit safe-area propagation at all. One
/// number, from the one place that always knows it.
enum SafeArea {
    #if canImport(UIKit)
    /// Top inset in points, or zero when there is no window yet — the caller
    /// takes the larger of this and the proxy's, so a zero here is harmless.
    static var top: Double {
        window.map { Double($0.safeAreaInsets.top) } ?? 0
    }

    static var bottom: Double {
        window.map { Double($0.safeAreaInsets.bottom) } ?? 0
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            // `.foregroundActive` first: an app with more than one scene can
            // hold a background one whose insets belong to another display.
            .sorted { a, _ in a.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
    #else
    // The package builds for macOS so the layout tests can run there; the
    // renderer itself is iOS-only.
    static var top: Double { 0 }
    static var bottom: Double { 0 }
    #endif
}

/// The box a screen is laid out into.
///
/// One line of arithmetic, and it lived inside a SwiftUI view body — where a
/// test cannot reach it. That is how the bottom inset stayed missing: the body
/// ran to the physical bottom of the display, a pinned footer resolved against
/// that, and every notched device put the CTA under the home indicator while
/// the dashboard preview showed it sitting clear. Nothing could have caught it,
/// because nothing could call it.
enum ScreenBox {
    /// The body between the chrome and the home indicator.
    ///
    /// `chrome` is the top bar's row; `safeTop` and `safeBottom` are the
    /// device's own insets. Clamped at zero so a short display with a tall
    /// chrome yields an empty box rather than a negative one — a negative
    /// height reaches the solver as a viewport nothing can be placed in.
    static func bodyHeight(
        display: Double, safeTop: Double, safeBottom: Double, chrome: Double
    ) -> Double {
        max(0, display - safeTop - safeBottom - chrome)
    }
}
