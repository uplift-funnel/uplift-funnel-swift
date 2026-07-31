import CoreGraphics
import Foundation
import UpliftLayout

/// Document in, pixels out — the whole v3 path in one call.
///
/// Four stages, each already tested on its own: decode resolves states and
/// conditions, the solver produces frames, the display list flattens them into
/// paint order, and the painter draws. Nothing here does any work; it exists so
/// that a caller — a view, a test, a screenshot tool — does not have to know the
/// order, and so that there is exactly one place the order is written down.
public struct ScreenRenderer {
    public var measurer: any TextMeasuring
    public var images: [String: CGImage]

    public init(measurer: any TextMeasuring = CoreTextMeasurer(), images: [String: CGImage] = [:]) {
        self.measurer = measurer
        self.images = images
    }

    /// The display list for a screen, ready to paint or to assert against.
    public func displayList(
        flow: [String: Any],
        screenIndex: Int,
        locale: String? = nil,
        input: LayoutInput = LayoutInput(),
        viewport: Viewport
    ) throws -> DisplayList {
        guard let tree = LayoutDecoder.layoutTree(
            flow: flow, screenIndex: screenIndex, locale: locale, input: input
        ) else {
            throw RenderFailure.noScreen(index: screenIndex)
        }
        let frames = try FlexSolver(measurer: measurer).solve(root: tree, viewport: viewport)
        return try DisplayListBuilder.build(root: tree, frames: frames, size: viewport.size)
    }

    /// A bitmap of a display list at a device scale.
    ///
    /// The context is flipped once, here, so everything downstream works in
    /// top-down screen points — the same coordinates the solver produced and
    /// the web reported. A painter that had to think in two coordinate systems
    /// would get one of them wrong eventually.
    public func image(_ list: DisplayList, scale: Double = 3, opaque: RGBA? = .white) -> CGImage? {
        let w = Int((list.size.width * scale).rounded())
        let h = Int((list.size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if let opaque {
            ctx.setFillColor(
                red: CGFloat(opaque.r), green: CGFloat(opaque.g),
                blue: CGFloat(opaque.b), alpha: CGFloat(opaque.a)
            )
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: CGFloat(list.size.height))
        ctx.scaleBy(x: 1, y: -1)
        // Off by default in a bitmap context, and text without it is unreadable
        // at 1×. It is deterministic, so goldens are unaffected.
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)

        FramePainter(measurer: measurer, images: images).paint(list, into: ctx)
        return ctx.makeImage()
    }

    public func render(
        flow: [String: Any],
        screenIndex: Int,
        locale: String? = nil,
        input: LayoutInput = LayoutInput(),
        viewport: Viewport,
        scale: Double = 3
    ) throws -> CGImage? {
        let list = try displayList(
            flow: flow, screenIndex: screenIndex, locale: locale,
            input: input, viewport: viewport
        )
        return image(list, scale: scale)
    }
}

public enum RenderFailure: Error, Equatable, Sendable {
    case noScreen(index: Int)
}
