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

    /// Hit count, for the test that proves the cache is doing anything.
    private(set) var builds = 0

    func model(for key: ScreenModelKey, build: () -> ScreenModel?) -> ScreenModel? {
        if key == self.key, let model { return model }
        builds += 1
        let built = build()
        self.key = key
        self.model = built
        return built
    }
}
