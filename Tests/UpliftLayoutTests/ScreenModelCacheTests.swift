import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// The screen model is built once per thing it depends on.
///
/// Two properties, and the second is the one worth testing. A cache that never
/// lets go is not a cache, it is a stale screen: an answer changes a state
/// delta, the delta changes a size, and the size moves every sibling below it.
/// So these assert the misses as carefully as the hits.
final class ScreenModelCacheTests: XCTestCase {
    private func key(
        answers: [String: String] = [:],
        width: Double = 390,
        screen: Int = 0,
        clockSecond: Int = 0
    ) -> ScreenModelKey {
        ScreenModelKey(
            flowVersion: "flow@1",
            screenIndex: screen,
            locale: "en",
            answers: answers,
            products: [:],
            width: width,
            height: 743,
            safeTop: 51,
            clockSecond: clockSecond
        )
    }

    private func stub() -> ScreenModel {
        let empty = DisplayList(size: Size2D(width: 1, height: 1), items: [])
        return ScreenModel(
            list: empty,
            interactions: InteractionMap(),
            rootScroll: nil,
            scrolling: empty,
            pinned: empty,
            fields: []
        )
    }

    func testTheSameKeyBuildsOnce() {
        let cache = ScreenModelCache()
        for _ in 0..<5 { _ = cache.model(for: key()) { self.stub() } }
        XCTAssertEqual(cache.builds, 1, "the model was rebuilt for an unchanged screen")
    }

    /// Every field of the key must invalidate. A missed one is a screen that
    /// stops responding to exactly that input.
    func testEveryDependencyInvalidates() {
        let cases: [(String, ScreenModelKey)] = [
            ("an answer", key(answers: ["plan": "monthly"])),
            ("a width", key(width: 320)),
            ("a screen index", key(screen: 1)),
            ("a countdown's second", key(clockSecond: 42)),
        ]
        for (what, changed) in cases {
            let cache = ScreenModelCache()
            _ = cache.model(for: key()) { self.stub() }
            _ = cache.model(for: changed) { self.stub() }
            XCTAssertEqual(cache.builds, 2, "\(what) did not invalidate the model")
        }
    }

    /// Images are NOT a dependency, and that is the point.
    ///
    /// Layout never reads them — the renderer takes them only to hand to the
    /// painter — so a photo arriving from the network must repaint without
    /// re-solving. Before this, image loading assigned one at a time and every
    /// assignment relaid out a screen that was already correct.
    func testImagesAreNotPartOfTheKey() {
        let mirror = Mirror(reflecting: key())
        let fields = mirror.children.compactMap(\.label)
        XCTAssertFalse(
            fields.contains("images"),
            "images entered the model key — a late photo now costs a full re-solve"
        )
        XCTAssertEqual(
            Set(fields),
            ["flowVersion", "screenIndex", "locale", "answers", "products",
             "width", "height", "safeTop", "clockSecond"],
            "the model key changed shape; check that the new field really "
            + "affects LAYOUT and not just paint"
        )
    }

    /// A screen with no countdown must never pay for one.
    ///
    /// `clockSecond` is the only key field that moves on its own, so it is the
    /// only one that could quietly undo the memo — a screen re-solving once a
    /// second forever for a feature it does not use. The view leaves it at zero
    /// unless the document actually carries a `behavior.countdown`.
    func testAScreenWithoutACountdownKeepsItsCache() {
        let cache = ScreenModelCache()
        for _ in 0..<20 { _ = cache.model(for: key()) { self.stub() } }
        XCTAssertEqual(cache.builds, 1, "a screen with no countdown re-solved")
    }

    /// And one WITH a countdown rebuilds once a second, not once a tick.
    ///
    /// The timer fires four times a second; three of those land in the same
    /// whole second and must hit the cache, or the ticking costs four solves
    /// per second instead of one.
    func testACountdownRebuildsOncePerSecondNotPerTick() {
        let cache = ScreenModelCache()
        // 0ms, 250ms, 500ms, 750ms, 1000ms — four ticks in second 0, one in second 1.
        for ms in [0, 250, 500, 750, 1000] {
            _ = cache.model(for: key(clockSecond: ms / 1000)) { self.stub() }
        }
        XCTAssertEqual(cache.builds, 2, "the countdown re-solved on every tick, not every second")
    }

    /// The countdown scan is asked on every body evaluation and answered once.
    func testTheCountdownScanIsMemoized() {
        let cache = ScreenModelCache()
        var scans = 0
        for _ in 0..<10 {
            _ = cache.hasCountdown(screenIndex: 0) {
                scans += 1
                return true
            }
        }
        XCTAssertEqual(scans, 1, "the raw-JSON scan ran on every body evaluation")
        _ = cache.hasCountdown(screenIndex: 1) {
            scans += 1
            return false
        }
        XCTAssertEqual(scans, 2, "a different screen reused the previous screen's answer")
    }
}
