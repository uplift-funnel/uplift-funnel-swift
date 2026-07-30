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
            h = try intrinsicSize(root, available: Size2D(width: w, height: viewport.size.height)).height
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
        let w = try resolvedWidth(n, available: available)
        let h = try resolvedHeight(n, available: available, width: w)
        return Size2D(width: lu(w), height: lu(h))
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
        return content + n.padding.horizontal + 2 * n.borderWidth
    }

    private func hugHeight(_ n: LayoutNode, available: Size2D) throws -> Double {
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
        var heights: [Double] = []
        for c in flow { heights.append(try intrinsicSize(c, available: inner).height) }
        let content: Double
        switch n.mode {
        case .column:
            content = heights.reduce(0, +) + n.gapMain * Double(flow.count - 1)
        case .row, .stack:
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

        // Pass one: what each child is before any free space is shared.
        //
        // A grow child's base is ZERO, not its content size. That is CSS's
        // `flex-basis: 0` — set together with `flex-grow` in css.ts — and it is
        // the difference between "share the leftover" and "share the leftover
        // on top of what I already take", which give different answers whenever
        // the children's content differs in size.
        var bases: [Double] = []
        var growWeights: [Double] = []
        for c in flow {
            let mainFill = horizontal ? c.width == .fill : c.height == .fill
            let weight = c.grow ?? (mainFill ? 1 : 0)
            growWeights.append(weight)
            if weight > 0 {
                bases.append(0)
            } else {
                let avail = Size2D(
                    width: horizontal ? content.width : content.width,
                    height: horizontal ? content.height : content.height
                )
                let s = try intrinsicSize(c, available: avail)
                bases.append(horizontal ? s.width : s.height)
            }
        }

        let used = bases.reduce(0, +) + gaps
        let free = mainExtent - used
        let totalWeight = growWeights.reduce(0, +)
        // Negative free space is NOT redistributed. css.ts sets `flexShrink: 0`
        // on any explicit main-axis size, so a 300pt hero inside a scrolling
        // column stays 300pt and the parent overflows — the scroll is the
        // answer, not squashing the child.
        var mains = bases
        if totalWeight > 0 && free > 0 {
            for i in mains.indices {
                mains[i] = lu(bases[i] + free * (growWeights[i] / totalWeight))
            }
        }

        // Where the run starts, when it does not fill the main axis.
        let mainAlign = (horizontal ? n.alignX : n.alignY) ?? .start
        let leftover = mainExtent - (mains.reduce(0, +) + gaps)
        var cursor = (horizontal ? content.x : content.y)
        if leftover > 0 {
            switch mainAlign {
            case .center: cursor += lu(leftover / 2)
            case .end: cursor += leftover
            case .start, .stretch: break
            }
        }

        for (i, child) in flow.enumerated() {
            let mainSize = mains[i]
            // The cross axis defaults to STRETCH, which is CSS's `align-items`
            // default and what css.ts emits when the author said nothing. It is
            // why a column's children are as wide as the column without asking.
            let crossAlign = (horizontal ? n.alignY : n.alignX) ?? .stretch
            let intrinsicCross = try intrinsicSize(
                child,
                available: Size2D(
                    width: horizontal ? mainSize : crossExtent,
                    height: horizontal ? crossExtent : mainSize
                )
            )
            let childCrossWanted = horizontal ? intrinsicCross.height : intrinsicCross.width
            let crossFill = horizontal ? child.height == .fill : child.width == .fill
            let explicitCross = horizontal
                ? isExplicit(child.height)
                : isExplicit(child.width)

            let crossSize: Double
            if crossFill || (crossAlign == .stretch && !explicitCross) {
                crossSize = crossExtent
            } else {
                crossSize = childCrossWanted
            }
            var crossPos = horizontal ? content.y : content.x
            if crossSize < crossExtent {
                switch crossAlign {
                case .center: crossPos += lu((crossExtent - crossSize) / 2)
                case .end: crossPos += crossExtent - crossSize
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
            cursor += mainSize + n.gapMain
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
        var x = content.x, y = content.y
        switch node.alignX ?? .start {
        case .center: x += lu((content.width - w) / 2)
        case .end: x = content.maxX - w
        case .stretch: w = content.width
        case .start: break
        }
        switch node.alignY ?? .start {
        case .center: y += lu((content.height - h) / 2)
        case .end: y = content.maxY - h
        case .stretch: h = content.height
        case .start: break
        }
        return Rect(x: x, y: y, width: w, height: h)
    }
}
