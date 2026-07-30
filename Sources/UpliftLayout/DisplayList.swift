/// The screen as a flat, ordered list of things to draw.
///
/// FLAT rather than a tree, and absolute rather than relative, because the
/// solver has already answered both questions: every frame is in screen
/// coordinates by the time it gets here. What remains is paint order and what
/// each item is clipped by, and expressing those as data rather than as a
/// stack machine is what makes the whole thing assertable — a test can say
/// "item 7 is a 2pt emerald stroke on a 14pt-cornered rect at exactly this
/// frame" without a drawing context, and a painter becomes a loop with no
/// decisions left in it.
///
/// The split matters for the port, too. Dart and Kotlin get to reuse this file's
/// arithmetic and write only the loop.

/// A rectangle with corner radii — the shape almost everything is drawn as.
public struct RoundedRect: Equatable, Sendable {
    public var rect: Rect
    public var corners: Corners

    public init(rect: Rect, corners: Corners) {
        self.rect = rect
        // Fitted here rather than at the draw site, so a `corner: 999` pill is
        // already a legal shape by the time anyone looks at it.
        self.corners = corners.fitted(in: Size2D(width: rect.width, height: rect.height))
    }
}

public enum TextAlign: String, Equatable, Sendable {
    case start, center, end
}

public enum PaintContent: Equatable, Sendable {
    /// A shaped run and the colour to lay it in. Per-segment colours live on
    /// the segments; this is the fallback for the ones that named none.
    case text(TextRunSpec, color: RGBA, align: TextAlign, maxLines: Int?)
    case image(url: String, fit: ImageFit, position: Point2D)
}

/// One node's worth of drawing.
public struct PaintItem: Equatable, Sendable {
    /// The dotted child path, matching the solver's frames and the web's
    /// `data-node-path` — so a wrong pixel names a node.
    public var path: String
    public var frame: Rect
    public var style: PaintStyle
    public var content: PaintContent?

    /// The clips this item sits inside, outermost first.
    ///
    /// Carried per item rather than pushed and popped. A flat list has no
    /// ordering hazard, survives being sorted by z, and a painter that forgets
    /// to pop cannot corrupt everything after it.
    public var clips: [RoundedRect]

    /// Padding plus border — what separates the border box from the content
    /// box. Text is laid inside it, which is what puts an input's placeholder
    /// on the control's centre line instead of jammed against its top edge.
    public var contentInset: Edges

    /// Opacity accumulated down the ancestor chain, already multiplied in.
    ///
    /// NOT the same as CSS, and worth being precise about: CSS `opacity`
    /// establishes a group, so two overlapping children of a 50% parent show
    /// the parent's composite at 50% rather than each child at 50%. Flattening
    /// differs exactly where descendants overlap. The corpus has six opacity
    /// values and none of them sit over an overlapping pair, so this is a
    /// deliberate simplification with a known edge rather than an oversight —
    /// group opacity needs an offscreen layer, which is the painter's business
    /// and not the display list's.
    public var opacity: Double

    public init(
        path: String,
        frame: Rect,
        style: PaintStyle = .none,
        content: PaintContent? = nil,
        clips: [RoundedRect] = [],
        opacity: Double = 1,
        contentInset: Edges = .zero
    ) {
        self.path = path
        self.frame = frame
        self.style = style
        self.content = content
        self.clips = clips
        self.opacity = opacity
        self.contentInset = contentInset
    }

    /// The box text and images are laid inside.
    public var contentBox: Rect {
        Rect(
            x: frame.x + contentInset.left,
            y: frame.y + contentInset.top,
            width: max(0, frame.width - contentInset.horizontal),
            height: max(0, frame.height - contentInset.vertical)
        )
    }

    /// The shape this item paints into.
    public var shape: RoundedRect { RoundedRect(rect: frame, corners: style.corners) }

    /// Whether a painter can skip it entirely.
    public var isEmpty: Bool {
        content == nil && style.isInvisible
            || opacity <= 0
            || frame.width <= 0 || frame.height <= 0
    }
}

public struct DisplayList: Equatable, Sendable {
    public var size: Size2D
    public var items: [PaintItem]

    public init(size: Size2D, items: [PaintItem]) {
        self.size = size
        self.items = items
    }

    /// Only what actually marks the screen, in paint order.
    public var drawable: [PaintItem] { items.filter { !$0.isEmpty } }

    public func item(at path: String) -> PaintItem? { items.first { $0.path == path } }

    /// The same list with some nodes' content dropped, box and all kept.
    ///
    /// For nodes a native control is laid over: the pill still needs its fill
    /// and its stroke — those are the document's design — but its text belongs
    /// to the `UITextField`, and drawing it as well would double it a fraction
    /// of a point off.
    public func withoutContent(at paths: Set<String>) -> DisplayList {
        guard !paths.isEmpty else { return self }
        return DisplayList(size: size, items: items.map { item in
            guard paths.contains(item.path) else { return item }
            var stripped = item
            stripped.content = nil
            return stripped
        })
    }

    /// The topmost node under a point, or nil.
    ///
    /// Backwards, because the last thing painted is the thing on top — the same
    /// order the painter runs in, reversed. Clips count: a node scrolled out of
    /// its container is not hittable even though its frame still says where it
    /// would be, which is the bug every hand-rolled hit test has.
    public func hitTest(_ point: Point2D) -> String? {
        for item in items.reversed() {
            guard item.frame.contains(point) else { continue }
            guard item.clips.allSatisfy({ $0.rect.contains(point) }) else { continue }
            return item.path
        }
        return nil
    }
}

public extension Rect {
    func contains(_ p: Point2D) -> Bool {
        p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height
    }
}

/// What the display list will not guess at.
public enum PaintUnsupported: Error, Equatable, Sendable {
    /// Four different border widths need four paths, and every renderer draws
    /// their corners slightly differently. Nothing in the corpus asks for one,
    /// so rather than pick a corner treatment nobody has looked at, this
    /// refuses — a uniform stroke drawn on all four edges would be exactly the
    /// kind of plausible wrong answer that ships.
    case perEdgeStroke(path: String)
}

public enum DisplayListBuilder {
    /// Walk the laid-out tree in paint order, pairing each node with its frame.
    ///
    /// Paint order is tree order: a later sibling covers an earlier one, and a
    /// child covers its parent. `z` re-sorts siblings without changing which
    /// subtree they belong to, exactly as `z-index` does among positioned
    /// siblings.
    public static func build(
        root: LayoutNode,
        frames: [SolvedFrame],
        size: Size2D,
        strict: Bool = true
    ) throws -> DisplayList {
        let byPath = Dictionary(frames.map { ($0.path, $0.rect) }) { a, _ in a }
        var items: [PaintItem] = []
        try emit(root, byPath: byPath, clips: [], opacity: 1, into: &items, strict: strict)
        return DisplayList(size: size, items: items)
    }

    private static func emit(
        _ n: LayoutNode,
        byPath: [String: Rect],
        clips: [RoundedRect],
        opacity: Double,
        into items: inout [PaintItem],
        strict: Bool
    ) throws {
        // A node the solver produced no frame for was laid out as invisible —
        // a condition that did not hold, a state that removed it. Skipping the
        // subtree is right; inventing a frame for it is not.
        guard let frame = byPath[n.path] else { return }

        if strict, let w = n.paint.stroke?.width,
           !(w.top == w.right && w.right == w.bottom && w.bottom == w.left) {
            throw PaintUnsupported.perEdgeStroke(path: n.path)
        }

        let combined = opacity * n.paint.opacity
        let item = PaintItem(
            path: n.path,
            frame: frame,
            style: n.paint,
            content: content(of: n),
            clips: clips,
            opacity: combined,
            contentInset: Edges(
                top: n.padding.top + n.borderWidth,
                right: n.padding.right + n.borderWidth,
                bottom: n.padding.bottom + n.borderWidth,
                left: n.padding.left + n.borderWidth
            )
        )
        items.append(item)

        guard !n.children.isEmpty else { return }
        // Children inherit this node's clip when it clips, and its accumulated
        // alpha either way. The clip is the node's own rounded shape, so a
        // photo inside a 14pt-cornered card is cut by the card.
        let childClips = n.clipsContent ? clips + [item.shape] : clips
        // `z` orders siblings only. Sorting the whole tree by z would let a
        // grandchild jump out of its parent's stacking context, which no
        // renderer on any of the three platforms does.
        let ordered = n.children.enumerated()
            .sorted { ($0.element.z ?? 0, $0.offset) < ($1.element.z ?? 0, $1.offset) }
            .map(\.element)
        for child in ordered {
            try emit(
                child, byPath: byPath, clips: childClips,
                opacity: combined, into: &items, strict: strict
            )
        }
    }

    private static func content(of n: LayoutNode) -> PaintContent? {
        if let image = n.image {
            return .image(url: image.url, fit: image.fit, position: image.position)
        }
        if let run = n.controlText ?? n.text {
            return .text(
                run,
                color: n.textColor ?? .black,
                align: n.textAlign,
                maxLines: n.maxLines
            )
        }
        return nil
    }
}
