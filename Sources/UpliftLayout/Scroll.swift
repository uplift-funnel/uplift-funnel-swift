/// How far a scroller's content actually reaches.
///
/// A post-pass over frames the solver has already produced, which is the whole
/// reason it can be trusted: it reads `[SolvedFrame]` and returns new
/// information, so it cannot move a box. The frames were already right — the
/// recorded baseline has the paywall's root at 743 with a child ending at
/// 916.95, which is Chromium's own answer — and what was missing was never the
/// arithmetic, only somewhere to put the extra 174 points.
///
/// CSS does not give a scroller's children unbounded room either. Inside
/// `overflow: auto` with a definite height, items keep their content sizes,
/// free space goes negative, `flex-shrink: 0` holds and the box overflows. The
/// solver already models exactly that (`mainAxisSizes` refuses to redistribute
/// negative free space), so this file only has to measure the result.

public struct ScrollFrame: Equatable, Sendable {
    public var path: String
    public var axis: ScrollAxis
    /// The scroller's own box — what the user sees through.
    public var viewport: Rect
    /// The region that scrolls past it. Always contains `viewport`.
    public var content: Rect

    public init(path: String, axis: ScrollAxis, viewport: Rect, content: Rect) {
        self.path = path
        self.axis = axis
        self.viewport = viewport
        self.content = content
    }

    /// How far past the viewport the content runs, on the scrolling axis.
    public var overflow: Double {
        axis == .vertical
            ? max(0, content.height - viewport.height)
            : max(0, content.width - viewport.width)
    }

    public var scrolls: Bool { overflow > 0 }
}

public enum ScrollGeometry {
    /// Every scrolling node, with the extent of what it holds.
    public static func scrollers(root: LayoutNode, frames: [SolvedFrame]) -> [ScrollFrame] {
        let byPath = Dictionary(frames.map { ($0.path, $0.rect) }) { a, _ in a }
        var out: [ScrollFrame] = []
        walk(root, byPath: byPath, into: &out)
        return out
    }

    private static func walk(
        _ n: LayoutNode, byPath: [String: Rect], into out: inout [ScrollFrame]
    ) {
        if let axis = n.scroll, let box = byPath[n.path] {
            out.append(ScrollFrame(
                path: n.path,
                axis: axis,
                viewport: box,
                content: extent(of: n, viewport: box, axis: axis, byPath: byPath)
            ))
        }
        for child in n.children { walk(child, byPath: byPath, into: &out) }
    }

    /// The union of the scroller's box with everything inside it that can be
    /// reached by scrolling.
    private static func extent(
        of n: LayoutNode, viewport: Rect, axis: ScrollAxis, byPath: [String: Rect]
    ) -> Rect {
        var minY = viewport.y, maxY = viewport.y + viewport.height
        var minX = viewport.x, maxX = viewport.x + viewport.width

        func absorb(_ node: LayoutNode, isScroller: Bool) {
            // A FIXED node resolves against the screen, not this box. It does
            // not scroll and it does not extend what scrolls.
            if node.position == .fixed { return }
            if let r = byPath[node.path] {
                minY = min(minY, r.y); maxY = max(maxY, r.y + r.height)
                minX = min(minX, r.x); maxX = max(maxX, r.x + r.width)
            }
            // Stop at anything that clips, and at a nested scroller: an
            // `overflow: hidden` box's own overflow does not reach outward, and
            // neither does a scroller's — it keeps it and scrolls it itself.
            // The paywall needs this immediately, where a photo overflows the
            // rounded card that clips it.
            if isScroller || node.clipsContent || node.scroll != nil { return }
            for child in node.children { absorb(child, isScroller: false) }
        }
        absorb(n, isScroller: true)
        for child in n.children { absorb(child, isScroller: false) }

        // CLAMPED to the scroller's own start on the scrolling axis, and to its
        // box entirely on the cross axis.
        //
        // Content before the block-start edge is unreachable in CSS — you
        // cannot scroll up past the top — and the paywall has exactly that: a
        // hero with `ignoreSafeArea` sitting at y = -51. Clamping keeps it
        // clipped, which is what the browser does and what the recorded goldens
        // already show. The cross axis is clamped because a vertical scroller
        // hides horizontal overflow rather than scrolling it.
        switch axis {
        case .vertical:
            return Rect(
                x: viewport.x, y: viewport.y,
                width: viewport.width, height: max(viewport.height, maxY - viewport.y)
            )
        case .horizontal:
            return Rect(
                x: viewport.x, y: viewport.y,
                width: max(viewport.width, maxX - viewport.x), height: viewport.height
            )
        }
    }
}
