import CoreText
import Foundation

/// Fonts, built once per (size, weight).
///
/// Its own file and its own type because it is the one piece of MUTABLE STATE
/// in the render path, and that deserves to be visible rather than tucked into
/// a static var. Everything else — the solver, the display list, the painter —
/// is a pure function of its arguments; this is a cache, and a reader looking
/// for "what can go stale here" should find exactly one answer.
///
/// A shared instance rather than one per measurer, because `CoreTextMeasurer`
/// is a struct constructed fresh at six call sites: a per-instance cache would
/// never hit. That makes it process-global, hence the lock.
final class FontStore: @unchecked Sendable {
    private struct Key: Hashable {
        /// The BIT PATTERN, not the value. Two sizes that compare equal always
        /// have equal bits here (the sizes come from a document, never from
        /// arithmetic that could produce -0 or a NaN), and bit identity is the
        /// conservative direction: a miss costs a font, a false hit would cost
        /// a wrong metric.
        let size: UInt64
        let weight: Int
    }

    private let lock = NSLock()
    private var cache: [Key: CTFont] = [:]

    /// Above this the cache is dropped wholesale rather than evicted by age.
    ///
    /// A real document uses a dozen (size, weight) pairs; a thousand means
    /// something is generating sizes, and an LRU would then spend more on
    /// bookkeeping than it saves. Dropping everything is one line, is
    /// deterministic, and cannot leak.
    private static let limit = 512

    func font(size: Double, weight: Int) -> CTFont {
        let key = Key(size: size.bitPattern, weight: weight)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Built OUTSIDE the lock. Font construction touches CoreText's own
        // caches and can be slow; holding the lock across it would serialise
        // every measurer in the process behind the first miss. The cost of the
        // race is that two threads may build the same font once each, and
        // since `makeFont` is pure they are interchangeable.
        let built = CoreTextMeasurer.makeFont(size: size, weight: weight)

        lock.lock()
        if cache.count >= Self.limit { cache.removeAll(keepingCapacity: true) }
        cache[key] = built
        lock.unlock()
        return built
    }

    func reset() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
