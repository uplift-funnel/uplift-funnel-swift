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
public struct PrimitiveCanvas: View {
    public var list: DisplayList
    public var painter: FramePainter
    /// The node path under the tap, for whoever owns the answers.
    public var onTap: (String) -> Void

    public init(
        list: DisplayList,
        painter: FramePainter = FramePainter(),
        onTap: @escaping (String) -> Void = { _ in }
    ) {
        self.list = list
        self.painter = painter
        self.onTap = onTap
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { gc, _ in
            gc.withCGContext { cg in
                painter.paint(list, into: cg)
            }
        }
        .frame(width: list.size.width, height: list.size.height)
        // Without this the canvas is only hittable where it drew something,
        // and a tap in a card's padding would miss the card.
        .contentShape(Rectangle())
        // A zero-distance drag rather than `onTapGesture`, so the hit point is
        // reported — a tap gesture gives no location.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard let path = list.hitTest(
                        Point2D(x: value.location.x, y: value.location.y)
                    ) else { return }
                    onTap(path)
                }
        )
    }
}
