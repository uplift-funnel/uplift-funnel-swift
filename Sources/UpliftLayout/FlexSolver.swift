/// The layout algorithm, as CSS flexbox performs it for the subset v3 defines.
///
/// The web renderer emits flexbox and lets Chromium do this. Reproducing it here
/// rather than approximating it with stacks is the whole design: SwiftUI's
/// negotiation is single-pass propose-and-choose, where a child's answer is
/// authoritative, and flexbox is two-pass — measure every child, then
/// distribute what is left over. No arrangement of HStack and VStack performs
/// the second pass, which is why v2's native renderers drifted.
///
/// Every size that lands in a frame goes through `lu()`. See Geometry.swift for
/// why that is a correctness requirement and not tidiness.

public struct FlexSolver: Sendable {
    private let measurer: any TextMeasuring

    public init(measurer: any TextMeasuring) {
        self.measurer = measurer
    }

    /// Lay a screen out and return every node's frame, in document order.
    public func solve(root: LayoutNode, viewport: Viewport) throws -> [SolvedFrame] {
        try LayoutPass(measurer: measurer).solve(root: root, viewport: viewport)
    }
}

/// One pass of the algorithm, and the only place it keeps state.
///
/// `FlexSolver` stays a `Sendable` struct that is a pure function of its
/// arguments; the memo lives HERE, on an object created inside `solve` and
/// discarded when it returns. That is the whole reason this type exists.
///
/// A memo on the solver itself would be a correctness bug rather than a
/// speed-up: `PrimitiveScreenV3` holds one solver and re-solves on every
/// keystroke, so an instance-lifetime cache keyed by path would hand back the
/// PREVIOUS answer's frames the moment a selection changed a delta. Per pass,
/// there is nothing to go stale. It also means two concurrent solves get two
/// memos and need no lock.
///
/// Why the memo is needed at all: `intrinsicSize` is called from seven sites
/// and recurses into whole subtrees. Measured on the paywall before this, 41
/// nodes produced 1,376 `intrinsicSize` calls and 1,930 text measurements — a
/// hundredfold re-measure of the same nineteen strings, because a row measures
/// its children once for the flex base, again for the cross size, and again
/// when placing them.
final class LayoutPass {
    private let measurer: any TextMeasuring

    /// `(path, offered width, offered height)` → the answer.
    ///
    /// Keyed on the BIT PATTERN of the two lengths rather than their value.
    /// Identical bits guarantee an identical answer, and anything else simply
    /// misses — the conservative direction, since a miss costs a measurement
    /// and a false hit would cost a wrong frame. It also makes the parity
    /// suite's NaN sentinel a stable, self-equal key instead of one that never
    /// matches and grows a bucket per insert.
    ///
    /// Keying on `path` is safe because path uniqueness is already load-bearing
    /// elsewhere: `DisplayListBuilder` builds a path→rect dictionary,
    /// `InteractionMap` is path-keyed, and `hitTest` returns one.
    private struct MemoKey: Hashable {
        let path: String
        let width: UInt64
        let height: UInt64
    }
    private var memo: [MemoKey: Size2D] = [:]

    init(measurer: any TextMeasuring) {
        self.measurer = measurer
    }

    func solve(root: LayoutNode, viewport: Viewport) throws -> [SolvedFrame] {
        var out: [SolvedFrame] = []
        // The root is sized like any other node, with one CSS fact standing in
        // for the parent it does not have: a block-level box is as WIDE as its
        // container whatever its content, and only its height hugs. Every other
        // node gets that for free from the cross-axis stretch; the root has
        // nothing to stretch against, so it is stated here.
        let w: Double
        switch root.width {
        case .points(let v): w = v
        case .hug, .fill: w = viewport.size.width
        case .percent: throw LayoutUnsupported.percentSize(path: root.path)
        }
        let h: Double
        switch root.height {
        case .points(let v): h = v
        case .fill: h = viewport.size.height
        case .percent: throw LayoutUnsupported.percentSize(path: root.path)
        case .hug:
            // CAPPED at the viewport. The screen body is the root's container,
            // so a document taller than the screen does not make the root
            // taller — it makes the root scroll. The paywall is 967pt of
            // content in a 743pt body and the browser reports the root at 743;
            // a root that hugged to 967 put the pinned footer 225pt below the
            // screen it is pinned to.
            h = min(
                try intrinsicSize(
                    root, available: Size2D(width: w, height: viewport.size.height)
                ).height,
                viewport.size.height
            )
        }
        try place(root, into: Rect(x: 0, y: 0, width: lu(w), height: lu(h)), viewport: viewport, out: &out)
        return out
    }

    // MARK: - measurement

    /// What a node wants to be, given how much room it is offered.
    ///
    /// `available` is the content box it may occupy. A `hug` node returns the
    /// size of its content; a `fill` node returns what it was offered. This is
    /// flexbox's first pass.
    func intrinsicSize(_ n: LayoutNode, available: Size2D) throws -> Size2D {
        let key = MemoKey(
            path: n.path,
            width: available.width.bitPattern,
            height: available.height.bitPattern
        )
        if let hit = memo[key] { return hit }

        var w = clamp(try resolvedWidth(n, available: available), n.minWidth, n.maxWidth)
        var h: Double

        // ASPECT derives whichever axis is not otherwise given. CSS
        // `aspect-ratio: N` means width ÷ height, so a 1.5 image that is 300
        // wide is 200 tall — and the editor puts 1.5 on every image it makes,
        // which is why ignoring this was shipping a wrong height for the most
        // common node there is.
        if let aspect = n.aspect, aspect > 0, case .hug = n.height {
            h = w / aspect
        } else {
            h = try resolvedHeight(n, available: available, width: w)
        }
        h = clamp(h, n.minHeight, n.maxHeight)
        // A clamped height feeds back into an aspect-driven width, the way CSS
        // resolves the pair — otherwise `aspect` plus `maxHeight` produces a
        // box whose sides do not match the ratio it was given.
        if let aspect = n.aspect, aspect > 0, case .hug = n.width, case .hug = n.height {
            w = clamp(h * aspect, n.minWidth, n.maxWidth)
        }

        let size = Size2D(
            width: quantised(w, when: n.width),
            height: quantised(h, when: n.height)
        )
        // SUCCESSES only. A `LayoutUnsupported` is deterministic in the same
        // arguments, so re-running it costs nothing and re-throws identically,
        // where caching a failure would mean deciding what a cached error means
        // for a node asked about twice.
        //
        // Quantisation happens above, INSIDE the memoised call, so what goes in
        // is already on the layout grid. That is what makes this incapable of
        // changing an answer rather than merely unlikely to.
        memo[key] = size
        return size
    }

    /// A content-derived size rounds UP to the grid; a declared or inherited one
    /// rounds down like every other length.
    ///
    /// The asymmetry is the point. Flooring a hug width makes the box narrower
    /// than the content that sized it, and the content then reflows inside it —
    /// text that fit on one line takes two, in an element built to hold it on
    /// one. A declared `.points(24)` has no such feedback loop, and `.fill` is
    /// the parent's number rather than the content's.
    private func quantised(_ value: Double, when size: Size) -> Double {
        if case .hug = size { return luCeil(value) }
        return lu(value)
    }

    /// `max` first, then `min` — the CSS order, in which a min-width larger
    /// than the max-width wins. Backwards, and deliberately so: the floor is a
    /// promise about the content fitting, and the ceiling is only a preference.
    private func clamp(_ value: Double, _ low: Double?, _ high: Double?) -> Double {
        var out = value
        if let high { out = min(out, high) }
        if let low { out = max(out, low) }
        return out
    }

    private func resolvedWidth(_ n: LayoutNode, available: Size2D) throws -> Double {
        switch n.width {
        case .points(let v): return v
        case .fill: return available.width
        case .percent: throw LayoutUnsupported.percentSize(path: n.path)
        case .hug: return try hugWidth(n, available: available)
        }
    }

    private func resolvedHeight(_ n: LayoutNode, available: Size2D, width: Double) throws -> Double {
        switch n.height {
        case .points(let v): return v
        case .fill: return available.height
        case .percent: throw LayoutUnsupported.percentSize(path: n.path)
        case .hug: return try hugHeight(n, available: Size2D(width: width, height: available.height))
        }
    }

    private func hugWidth(_ n: LayoutNode, available: Size2D) throws -> Double {
        if let run = n.text {
            var r = run
            let inner = available.width - n.padding.horizontal - 2 * n.borderWidth
            r.maxWidth = inner
            let m = measurer.measure(r)
            // FIT-CONTENT, not the widest line. A text node renders as a block
            // and CSS sizes it to `min(max-content, available)` — so a sentence
            // long enough to wrap occupies the WHOLE box, even though every one
            // of its lines is shorter than the box. Returning the widest line
            // instead narrows the element, which then narrows its parent, and
            // the error compounds up the tree: it is what made the welcome
            // screen's column come out 318.83 wide instead of 342.
            let width = m.lines.count > 1 ? inner : m.width
            return width + n.padding.horizontal + 2 * n.borderWidth
        }
        guard !n.children.isEmpty else { return 0 }
        let inner = Size2D(
            width: available.width - n.padding.horizontal - 2 * n.borderWidth,
            height: available.height - n.padding.vertical - 2 * n.borderWidth
        )
        let flow = n.children.filter { $0.position == .relative }
        var widths: [Double] = []
        for c in flow { widths.append(try intrinsicSize(c, available: inner).width) }
        guard !widths.isEmpty else { return 0 }
        let content: Double
        switch n.mode {
        case .row:
            content = widths.reduce(0, +) + n.gapMain * Double(flow.count - 1)
        case .column, .stack:
            content = widths.max() ?? 0
        case .grid, .wrap:
            throw LayoutUnsupported.mode(n.mode, path: n.path)
        }
        // Capped at what is on offer, which is what makes `hug` mean CSS's
        // fit-content — `min(max-content, available)` — for a box and not just
        // for text. Uncapped, an option row asked for 373pt in the 342pt it was
        // going to get, and its HEIGHT was then measured at 373: the subtitle
        // fit on one line at a width the row never had, so the row came out a
        // whole line short and every row below it rode up the screen.
        return min(content + n.padding.horizontal + 2 * n.borderWidth, available.width)
    }

    private func hugHeight(_ n: LayoutNode, available: Size2D) throws -> Double {
        if let h = n.controlHeight { return h }
        if let run = n.text {
            var r = run
            r.maxWidth = available.width - n.padding.horizontal
            return measurer.measure(r).height + n.padding.vertical + 2 * n.borderWidth
        }
        guard !n.children.isEmpty else { return 0 }
        let inner = Size2D(
            width: available.width - n.padding.horizontal - 2 * n.borderWidth,
            height: available.height - n.padding.vertical - 2 * n.borderWidth
        )
        let flow = n.children.filter { $0.position == .relative }
        guard !flow.isEmpty else { return n.padding.vertical + 2 * n.borderWidth }

        let content: Double
        switch n.mode {
        case .column, .stack:
            var heights: [Double] = []
            for c in flow { heights.append(try intrinsicSize(c, available: inner).height) }
            content = n.mode == .column
                ? heights.reduce(0, +) + n.gapMain * Double(flow.count - 1)
                : (heights.max() ?? 0)

        case .row:
            // Each child measured at the width it will actually be given, not
            // at the row's whole content box. The two differ for every row with
            // more than one child, and the error is not small: a growing text
            // column measured at the full 310pt fits its subtitle on one line,
            // where at its real 277pt share the subtitle takes two — so the row
            // came out a whole line short and everything below it rode up.
            //
            // The recorded-metrics measurer cannot see this. It replays fixed
            // line counts per string, so the text does not re-wrap however wrong
            // the width is, and the bug only appears once a real shaper answers.
            let gaps = n.gapMain * Double(max(0, flow.count - 1))
            let widths = try mainAxisSizes(
                flow: flow,
                available: inner,
                mainExtent: inner.width,
                gaps: gaps,
                horizontal: true
            )
            var heights: [Double] = []
            for (i, c) in flow.enumerated() {
                heights.append(
                    try intrinsicSize(
                        c, available: Size2D(width: widths[i], height: inner.height)
                    ).height
                )
            }
            content = heights.max() ?? 0

        case .grid, .wrap:
            throw LayoutUnsupported.mode(n.mode, path: n.path)
        }
        return content + n.padding.vertical + 2 * n.borderWidth
    }

    // MARK: - placement

    private func place(
        _ n: LayoutNode,
        into rect: Rect,
        viewport: Viewport,
        out: inout [SolvedFrame]
    ) throws {
        out.append(SolvedFrame(path: n.path, rect: rect.quantised))

        guard !n.children.isEmpty else { return }
        if n.mode == .grid || n.mode == .wrap {
            throw LayoutUnsupported.mode(n.mode, path: n.path)
        }

        // Border-box sizing: the border sits INSIDE the frame and the content
        // box is what is left after it and the padding.
        let b = n.borderWidth
        let content = Rect(
            x: rect.x + n.padding.left + b,
            y: rect.y + n.padding.top + b,
            width: rect.width - n.padding.horizontal - 2 * b,
            height: rect.height - n.padding.vertical - 2 * b
        )

        // Out-of-flow children resolve against this box and take no part in the
        // distribution — the same split CSS makes between `position: relative`
        // and everything else.
        for child in n.children where child.position != .relative {
            try placeOutOfFlow(child, in: rect, viewport: viewport, out: &out)
        }
        let flow = n.children.filter { $0.position == .relative }
        guard !flow.isEmpty else { return }

        if n.mode == .stack {
            // Every child gets the whole content box; `fill` spans it, `hug`
            // sits at its own size against the box's alignment.
            for child in flow {
                let size = try intrinsicSize(child, available: content.size)
                let r = alignedRect(child, size: size, in: content, node: n)
                try place(child, into: r, viewport: viewport, out: &out)
            }
            return
        }

        try placeFlow(n, flow: flow, content: content, viewport: viewport, out: &out)
    }

    /// How the main axis is divided between the children.
    ///
    /// Pulled out of placement because MEASURING needs the same answer. A row
    /// that hugs its height has to know how tall its children are, and a child's
    /// height depends on how wide it ends up — so the widths have to be settled
    /// before the heights are asked for, exactly as they are when placing.
    private func mainAxisSizes(
        flow: [LayoutNode],
        available: Size2D,
        mainExtent: Double,
        gaps: Double,
        horizontal: Bool
    ) throws -> [Double] {
        // Pass one: what each child is before any free space is shared.
        //
        // A grow child's base is ZERO, not its content size. That is CSS's
        // `flex-basis: 0` — set together with `flex-grow` in css.ts — and it is
        // the difference between "share the leftover" and "share the leftover
        // on top of what I already take", which give different answers whenever
        // the children's content differs in size.
        var bases: [Double] = []
        var growWeights: [Double] = []
        var marginMain = 0.0
        for c in flow {
            let mainFill = horizontal ? c.width == .fill : c.height == .fill
            let weight = c.grow ?? (mainFill ? 1 : 0)
            growWeights.append(weight)
            if weight > 0 {
                bases.append(0)
            } else {
                let s = try intrinsicSize(c, available: available)
                bases.append(horizontal ? s.width : s.height)
            }
            // MARGIN is outside the border box, so it takes main-axis room the
            // children then have less of. Added to the used space rather than
            // to the base, because a growing child's base is zero and its
            // margin is not.
            marginMain += horizontal ? c.margin.horizontal : c.margin.vertical
        }

        let free = mainExtent - (bases.reduce(0, +) + gaps + marginMain)
        let totalWeight = growWeights.reduce(0, +)
        // Negative free space is NOT redistributed. css.ts sets `flexShrink: 0`
        // on any explicit main-axis size, so a 300pt hero inside a scrolling
        // column stays 300pt and the parent overflows — the scroll is the
        // answer, not squashing the child.
        guard totalWeight > 0, free > 0 else { return bases }
        return bases.indices.map { lu(bases[$0] + free * (growWeights[$0] / totalWeight)) }
    }

    /// The two-pass distribution: base sizes, then free space by grow weight.
    private func placeFlow(
        _ n: LayoutNode,
        flow: [LayoutNode],
        content: Rect,
        viewport: Viewport,
        out: inout [SolvedFrame]
    ) throws {
        let horizontal = n.mode == .row
        let mainExtent = horizontal ? content.width : content.height
        let crossExtent = horizontal ? content.height : content.width
        let gaps = n.gapMain * Double(max(0, flow.count - 1))

        let mains = try mainAxisSizes(
            flow: flow,
            available: content.size,
            mainExtent: mainExtent,
            gaps: gaps,
            horizontal: horizontal
        )

        // Where the run starts, and how the leftover is shared.
        let mainAlign = (horizontal ? n.alignX : n.alignY) ?? .start
        let marginTotal = flow.reduce(0.0) {
            $0 + (horizontal ? $1.margin.horizontal : $1.margin.vertical)
        }
        let leftover = mainExtent - (mains.reduce(0, +) + gaps + marginTotal)
        var cursor = (horizontal ? content.x : content.y)
        // `distribute` is CSS `justify-content` past start/centre/end, and it
        // takes precedence over the alignment: a row that says `between` has
        // already answered where its children go.
        var spread = 0.0
        if leftover > 0, flow.count > 1, n.distribute != .packed {
            switch n.distribute {
            case .between:
                spread = leftover / Double(flow.count - 1)
            case .around:
                // Half a gap at each end, a full gap between — each child gets
                // an equal margin, so the outer ones look half as spaced.
                spread = leftover / Double(flow.count)
                cursor += lu(spread / 2)
            case .evenly:
                spread = leftover / Double(flow.count + 1)
                cursor += lu(spread)
            case .packed:
                break
            }
        } else if leftover > 0 {
            switch mainAlign {
            case .center: cursor += lu(leftover / 2)
            case .end: cursor += leftover
            case .start, .stretch: break
            }
        }

        for (i, child) in flow.enumerated() {
            let mainSize = mains[i]
            // The leading margin pushes this child along before it is placed.
            cursor += horizontal ? child.margin.left : child.margin.top
            // The cross axis defaults to STRETCH, which is CSS's `align-items`
            // default and what css.ts emits when the author said nothing. It is
            // why a column's children are as wide as the column without asking.
            let crossAlign = (horizontal ? n.alignY : n.alignX) ?? .stretch
            // MARGIN comes out of the cross axis as well as the main one.
            // `align-items: stretch` gives the child the container's cross size
            // MINUS its own margins, so a negative margin makes it BIGGER —
            // which is how a full-bleed hero escapes its parent's padding.
            //
            // Only the main axis was accounted for, and the paywall shows what
            // that costs: a 220pt hero with `margin: [0, -24, 0, -24]` in a
            // 342pt column was moved to x = 0 correctly and then left 342 wide,
            // so it stopped 48pt short of the right edge of a screen it is
            // supposed to bleed across. Measured in Chromium: 390, and 322 for
            // the same box with `margin: 0 10px`.
            let crossMargin = horizontal ? child.margin.vertical : child.margin.horizontal
            let crossAvailable = crossExtent - crossMargin
            let intrinsicCross = try intrinsicSize(
                child,
                available: Size2D(
                    width: horizontal ? mainSize : crossAvailable,
                    height: horizontal ? crossAvailable : mainSize
                )
            )
            let childCrossWanted = horizontal ? intrinsicCross.height : intrinsicCross.width
            let crossFill = horizontal ? child.height == .fill : child.width == .fill
            let explicitCross = horizontal
                ? isExplicit(child.height)
                : isExplicit(child.width)

            var crossSize: Double
            if crossFill || (crossAlign == .stretch && !explicitCross) {
                crossSize = crossAvailable
            } else {
                crossSize = childCrossWanted
            }
            // A STRETCHED child is still bounded. `align-items: stretch` hands
            // the container's cross size to the child, but `max-width` clamps
            // what it may accept — so a card with `maxWidth: 400` in a 600pt
            // column is 400 wide, not 600. Clamping only inside `intrinsicSize`
            // missed this entirely, because stretch replaces that answer.
            crossSize = horizontal
                ? clamp(crossSize, child.minHeight, child.maxHeight)
                : clamp(crossSize, child.minWidth, child.maxWidth)
            var crossPos = (horizontal ? content.y : content.x)
                + (horizontal ? child.margin.top : child.margin.left)
            // The free space an alignment shares out is what is left AFTER the
            // margins, which is why `crossAvailable` and not `crossExtent`
            // appears here too: Chromium centres a 100pt box with a 40pt right
            // margin in a 342pt column at x = 125, not 145.
            if crossSize < crossAvailable {
                switch crossAlign {
                case .center: crossPos += lu((crossAvailable - crossSize) / 2)
                case .end: crossPos += crossAvailable - crossSize
                case .start, .stretch: break
                }
            }

            var r = horizontal
                ? Rect(x: cursor, y: crossPos, width: mainSize, height: crossSize)
                : Rect(x: crossPos, y: cursor, width: crossSize, height: mainSize)
            // `ignoreSafeArea` — a full-bleed hero reaching the top of the
            // display. The web does it with a negative top margin cancelling
            // the host's safe-area padding, so it pulls the node up AND
            // everything after it in the flow: a margin changes the flow, it
            // does not merely offset the painted box.
            if child.ignoreSafeArea && !horizontal {
                r.y -= viewport.safeTop
                cursor -= viewport.safeTop
            }
            try place(child, into: r, viewport: viewport, out: &out)
            cursor += mainSize + n.gapMain + spread
            cursor += horizontal ? child.margin.right : child.margin.bottom
        }
    }

    /// `absolute` and `fixed`: insets win, anchors decide what an absent inset
    /// means, and the node is out of the parent's flow entirely.
    private func placeOutOfFlow(
        _ n: LayoutNode,
        in container: Rect,
        viewport: Viewport,
        out: inout [SolvedFrame]
    ) throws {
        let box = n.position == .fixed
            ? Rect(x: 0, y: 0, width: viewport.size.width, height: viewport.size.height)
            : container
        let inset = n.inset ?? .zero
        let has = n.insetSides

        let size = try intrinsicSize(n, available: box.size)
        var w = size.width
        var h = size.height
        // Opposite insets both given pin both edges, which sizes the node.
        if has.left && has.right { w = box.width - inset.left - inset.right }
        if has.top && has.bottom { h = box.height - inset.top - inset.bottom }

        var x = box.x
        if has.left { x = box.x + inset.left }
        else if has.right { x = box.maxX - inset.right - w }
        else {
            switch n.anchorX ?? .start {
            case .center: x = box.x + lu((box.width - w) / 2)
            case .end: x = box.maxX - w
            case .stretch: x = box.x; w = box.width
            case .start: x = box.x
            }
        }

        var y = box.y
        if has.top { y = box.y + inset.top }
        else if has.bottom { y = box.maxY - inset.bottom - h }
        else {
            switch n.anchorY ?? .start {
            case .center: y = box.y + lu((box.height - h) / 2)
            case .end: y = box.maxY - h
            case .stretch: y = box.y; h = box.height
            case .start: y = box.y
            }
        }

        try place(n, into: Rect(x: x, y: y, width: w, height: h), viewport: viewport, out: &out)
    }

    // MARK: - helpers

    private func isExplicit(_ s: Size) -> Bool {
        if case .hug = s { return false }
        if case .fill = s { return false }
        return true
    }

    private func alignedRect(_ child: LayoutNode, size: Size2D, in content: Rect, node: LayoutNode) -> Rect {
        var w = size.width, h = size.height
        if child.width == .fill { w = content.width }
        if child.height == .fill { h = content.height }
        // Same bound as the flow path: filling a stack does not license a child
        // to exceed a size it declared it would not.
        w = clamp(w, child.minWidth, child.maxWidth)
        h = clamp(h, child.minHeight, child.maxHeight)
        var x = content.x, y = content.y
        switch node.alignX ?? .start {
        case .center: x += lu((content.width - w) / 2)
        case .end: x = content.maxX - w
        case .stretch: w = clamp(content.width, child.minWidth, child.maxWidth)
        case .start: break
        }
        switch node.alignY ?? .start {
        case .center: y += lu((content.height - h) / 2)
        case .end: y = content.maxY - h
        case .stretch: h = clamp(content.height, child.minHeight, child.maxHeight)
        case .start: break
        }
        return Rect(x: x, y: y, width: w, height: h)
    }
}
