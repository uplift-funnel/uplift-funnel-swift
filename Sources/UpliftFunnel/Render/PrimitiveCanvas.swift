import SwiftUI
import UpliftLayout

/// The v3 screen, on screen.
///
/// One `Canvas` and one painter, which is the whole point of the architecture:
/// there is no view per node, so there is no SwiftUI layout pass to disagree
/// with the solver. The frames came from `FlexSolver`, were checked against
/// Chromium node by node, and are drawn exactly where they were computed.
///
/// `withCGContext` is what lets the golden and the device share a painter. A
/// `Canvas` hands out a `GraphicsContext`, but underneath it is a CGContext in
/// the same top-down coordinates the solver works in — so the code that draws
/// the test bitmap is the code that draws the phone, rather than a second
/// implementation that has to be kept in step.
public extension Color {
    /// The layout core's colour as SwiftUI's.
    ///
    /// The core has its own `RGBA` because it may not import SwiftUI — it is
    /// the file Dart and Kotlin will be ports of. This is the one adapter.
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

public struct PrimitiveCanvas: View {
    public var list: DisplayList
    public var painter: FramePainter
    /// The box to draw into. Usually the list's own size, but a scrolling body
    /// draws at its CONTENT size while the pinned layer over it draws at the
    /// viewport's — two canvases, two sizes, one display list each.
    public var size: Size2D
    /// Only these paths are hittable, or nil for all of them. The pinned layer
    /// sits over the whole screen and must not swallow taps meant for the body
    /// scrolling underneath it.
    public var hittable: Set<String>?
    /// The node path under the tap, for whoever owns the answers.
    public var onTap: (String) -> Void

    public init(
        list: DisplayList,
        painter: FramePainter = FramePainter(),
        size: Size2D? = nil,
        hittable: Set<String>? = nil,
        onTap: @escaping (String) -> Void = { _ in }
    ) {
        self.list = list
        self.painter = painter
        self.size = size ?? list.size
        self.hittable = hittable
        self.onTap = onTap
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { gc, _ in
            gc.withCGContext { cg in
                painter.paint(list, into: cg)
            }
        }
        .frame(width: size.width, height: size.height)
        // Without this the canvas is only hittable where it drew something,
        // and a tap in a card's padding would miss the card. A layer that only
        // holds pinned furniture gets the union of those frames instead, so the
        // body scrolling underneath it still receives the drag.
        .contentShape(HitRegion(list: list, only: hittable))
        // A TAP recogniser, not a zero-distance drag.
        //
        // The drag was here because a tap gesture used to give no location.
        // `SpatialTapGesture` does, and the distinction is not cosmetic inside
        // a `ScrollView`: a zero-distance drag competes with the pan recogniser
        // and either eats the scroll or fires a phantom tap when one ends.
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard let path = list.hitTest(
                        Point2D(x: value.location.x, y: value.location.y)
                    ) else { return }
                    onTap(path)
                }
        )
    }
}


/// The area a canvas answers for.
///
/// A full-screen rectangle for the body; for the pinned layer, only the frames
/// it actually draws. Without the second case a footer's transparent canvas
/// would cover the screen and absorb every scroll gesture aimed at the body
/// behind it.
private struct HitRegion: Shape {
    let list: DisplayList
    let only: Set<String>?

    func path(in rect: CGRect) -> Path {
        guard let only else { return Path(rect) }
        var path = Path()
        for item in list.items where only.contains(item.path) {
            path.addRect(CGRect(
                x: item.frame.x, y: item.frame.y,
                width: item.frame.width, height: item.frame.height
            ))
        }
        return path
    }
}
