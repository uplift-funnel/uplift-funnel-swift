import Foundation
import UpliftLayout

/// Everything a screen needs to draw and react, built once.
///
/// The decode-solve-build chain is not something to run casually: it walks the
/// document, measures every string and lays out every node. Before this it ran
/// from SwiftUI computed properties, which meant it ran on every `body` — twice
/// for the interaction map, because `fields(_:)` was called at two call sites —
/// and three times per TAP, because `tap` reached for `interactions` once to
/// find the handler, again to apply the answer and again to ask about
/// auto-advance.
struct ScreenModel {
    var list: DisplayList
    var interactions: InteractionMap

    /// The root scroller, when the screen has one and it actually overflows.
    ///
    /// Only the root in v1. Both fixtures put `scroll` there and nowhere else,
    /// and a nested scroller is not a small extension: a `Canvas` cannot host a
    /// subview, so each scroll container needs its own canvas positioned at its
    /// solved frame. That is a coherent design and worth building against real
    /// carousel requirements — snap, peek, paging — rather than speculatively.
    var rootScroll: ScrollFrame?

    /// How far the screen reaches ABOVE the body box, and therefore how much
    /// taller than that box the view has to be.
    ///
    /// A node carrying `ignoreSafeArea` is solved at a negative y — it is meant
    /// to bleed under the status bar — and the body it lives in starts below the
    /// safe area. Without this the two lists are drawn from the body's own top
    /// edge and the lifted band is simply cropped: the hero reached the frame it
    /// was given and none of the display it was reaching for.
    ///
    /// Both lists below are already translated by it, so every frame in them is
    /// in the view's coordinates. Zero for every screen with nothing lifted, and
    /// then this whole mechanism costs nothing.
    var lift: Double = 0

    /// Everything that scrolls with the body.
    var scrolling: DisplayList
    /// Everything pinned to the screen — `position: fixed`. Drawn over the
    /// scroll view, so a footer stays put while the body moves under it.
    var pinned: DisplayList
    /// Input nodes paired with their frames, for the native overlays. Sorted by
    /// path so the view identity is stable across rebuilds — an unordered
    /// dictionary would reshuffle the overlays and drop the keyboard mid-word.
    var fields: [(target: TapTarget, item: PaintItem)]
}

/// What a rebuild depends on.
///
/// `images` is DELIBERATELY ABSENT. Layout never reads them — `ScreenRenderer`
/// takes them only to hand to the painter — so a photo arriving from the
/// network repaints without re-solving. That is most of the first-appearance
/// stutter gone on its own: image loading used to assign one at a time into
/// `@State`, so N images meant N full relayouts of a screen that was already on
/// screen and already correct.
///
/// The flow is `[String: Any]` and cannot be hashed, so its identity travels as
/// a cheap version string the host already knows.
struct ScreenModelKey: Hashable {
    var flowVersion: String
    var screenIndex: Int
    var locale: String?
    var answers: [String: String]
    var products: [String: [String: String]]
    var width: Double
    var height: Double
    var safeTop: Double
    /// Whole seconds of the clock, for a screen carrying a countdown; 0 for
    /// every other screen.
    ///
    /// SECONDS, not milliseconds, and only when there is something to tick:
    /// keying on the raw clock would miss the cache on every frame and undo
    /// the memo entirely, and keying on it for screens without a countdown
    /// would do that to screens that have no reason to re-solve at all.
    var clockSecond: Int = 0
}

/// A one-entry memo, held by the view across body evaluations.
///
/// A reference type kept in `@State` and mutated THROUGH the reference, never
/// reassigned — so SwiftUI never sees a state mutation during a view update.
/// Not an `ObservableObject`: publishing a change here would invalidate the
/// view that just built the model and loop.
///
/// One entry rather than a dictionary. A screen is rebuilt with a changed key
/// far more often than it returns to an old one — a keystroke changes the
/// answers on every character — so a larger cache would hold a growing pile of
/// screens nobody will ask for again.
final class ScreenModelCache {
    private var key: ScreenModelKey?
    private var model: ScreenModel?
    private var countdownFor: Int?
    private var countdown = false

    /// Hit count, for the test that proves the cache is doing anything.
    private(set) var builds = 0

    /// Whether this screen carries a `behavior.countdown`, computed once.
    ///
    /// Asked on every body evaluation and answered by scanning raw JSON, so it
    /// is memoized alongside the model. It decides whether a timer is created
    /// at all — a screen without a countdown must not be woken four times a
    /// second for a feature it does not use.
    func hasCountdown(screenIndex: Int, compute: () -> Bool) -> Bool {
        if countdownFor == screenIndex { return countdown }
        countdown = compute()
        countdownFor = screenIndex
        return countdown
    }

    func model(for key: ScreenModelKey, build: () -> ScreenModel?) -> ScreenModel? {
        if key == self.key, let model { return model }
        builds += 1
        let built = build()
        self.key = key
        self.model = built
        return built
    }
}
