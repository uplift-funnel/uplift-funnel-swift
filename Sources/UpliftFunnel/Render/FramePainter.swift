import CoreGraphics
import CoreText
import Foundation
import UpliftLayout

/// The display list, drawn.
///
/// CoreGraphics rather than SwiftUI, and the reason is testability rather than
/// taste: this draws into any `CGContext`, so a golden is a bitmap produced in a
/// plain `swift test` process with no view hierarchy, no run loop and no host
/// app. A SwiftUI painter would need `ImageRenderer`, which needs a rendering
/// environment, which is the thing that makes UI goldens flaky.
///
/// There are no decisions left in here. Ordering, clipping, alpha and state
/// resolution all happened upstream in `DisplayListBuilder`; this file is a
/// loop over items and a switch over shapes. That is the point of the split —
/// when a screenshot is wrong, the question "is it the geometry or the paint"
/// has already been answered by whichever of the two test suites failed.
public struct FramePainter {
    public var measurer: any TextMeasuring
    /// Images already fetched, by URL. A painter never blocks on the network:
    /// an absent image draws its placeholder and the frame is still correct,
    /// which is what lets a golden run offline.
    public var images: [String: CGImage]

    public init(measurer: any TextMeasuring = CoreTextMeasurer(), images: [String: CGImage] = [:]) {
        self.measurer = measurer
        self.images = images
    }

    public func paint(_ list: DisplayList, into ctx: CGContext) {
        for item in list.drawable {
            ctx.saveGState()
            defer { ctx.restoreGState() }

            for clip in item.clips {
                ctx.addPath(path(clip))
                ctx.clip()
            }
            ctx.setAlpha(CGFloat(item.opacity))

            // Transforms turn about the node's own centre, which is what CSS
            // does with the default `transform-origin` and what the paywall's
            // rotated tail assumes. Applied around the frame's midpoint rather
            // than the origin, or a 45° rotation would also fling the node.
            if !item.style.transform.isIdentity {
                let t = item.style.transform
                let cx = item.frame.x + item.frame.width / 2
                let cy = item.frame.y + item.frame.height / 2
                ctx.translateBy(x: CGFloat(cx + t.translate.x), y: CGFloat(cy + t.translate.y))
                ctx.rotate(by: CGFloat(t.rotate * .pi / 180))
                ctx.scaleBy(x: CGFloat(t.scale), y: CGFloat(t.scale))
                ctx.translateBy(x: CGFloat(-cx), y: CGFloat(-cy))
            }

            let shape = item.shape
            for shadow in item.style.shadows where !shadow.inset {
                drawShadow(shadow, shape: shape, in: ctx)
            }
            // Before the fill, because a frosted panel is the blurred backdrop
            // with a translucent wash ON TOP of it.
            if let radius = item.style.backdropBlur {
                drawBackdrop(blur: radius, shape: shape, ctx: ctx)
            }
            if let fill = item.style.fill {
                draw(fill, in: shape, ctx: ctx)
            }
            if let content = item.content {
                draw(content, in: item, ctx: ctx)
            }
            if let stroke = item.style.stroke {
                draw(stroke, in: shape, ctx: ctx)
            }
        }
    }

    // MARK: - shapes

    /// A rounded rectangle as a path, corner by corner.
    ///
    /// Built by hand rather than with `CGPath(roundedRect:cornerWidth:...)`
    /// because that one takes a single radius for all four corners, and the
    /// schema allows four. The arcs are quarter-circles joined by lines, which
    /// is what CSS draws when the radii are equal on both axes.
    func path(_ shape: RoundedRect) -> CGPath {
        let r = shape.rect
        let c = shape.corners
        let p = CGMutablePath()
        let minX = CGFloat(r.x), minY = CGFloat(r.y)
        let maxX = CGFloat(r.x + r.width), maxY = CGFloat(r.y + r.height)
        guard !c.isSquare else {
            p.addRect(CGRect(x: minX, y: minY, width: CGFloat(r.width), height: CGFloat(r.height)))
            return p
        }
        p.move(to: CGPoint(x: minX + CGFloat(c.topLeft), y: minY))
        p.addLine(to: CGPoint(x: maxX - CGFloat(c.topRight), y: minY))
        p.addArc(
            tangent1End: CGPoint(x: maxX, y: minY),
            tangent2End: CGPoint(x: maxX, y: minY + CGFloat(c.topRight)),
            radius: CGFloat(c.topRight)
        )
        p.addLine(to: CGPoint(x: maxX, y: maxY - CGFloat(c.bottomRight)))
        p.addArc(
            tangent1End: CGPoint(x: maxX, y: maxY),
            tangent2End: CGPoint(x: maxX - CGFloat(c.bottomRight), y: maxY),
            radius: CGFloat(c.bottomRight)
        )
        p.addLine(to: CGPoint(x: minX + CGFloat(c.bottomLeft), y: maxY))
        p.addArc(
            tangent1End: CGPoint(x: minX, y: maxY),
            tangent2End: CGPoint(x: minX, y: maxY - CGFloat(c.bottomLeft)),
            radius: CGFloat(c.bottomLeft)
        )
        p.addLine(to: CGPoint(x: minX, y: minY + CGFloat(c.topLeft)))
        p.addArc(
            tangent1End: CGPoint(x: minX, y: minY),
            tangent2End: CGPoint(x: minX + CGFloat(c.topLeft), y: minY),
            radius: CGFloat(c.topLeft)
        )
        p.closeSubpath()
        return p
    }

    private func cg(_ c: RGBA) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(c.a)]
        ) ?? CGColor(gray: 0, alpha: CGFloat(c.a))
    }

    // MARK: - fills

    private func draw(_ paint: Paint, in shape: RoundedRect, ctx: CGContext) {
        switch paint {
        case .flat(let color):
            ctx.setFillColor(cg(color))
            ctx.addPath(path(shape))
            ctx.fillPath()

        case .linear(let angle, let stops):
            guard let gradient = gradient(stops) else { return }
            ctx.saveGState()
            ctx.addPath(path(shape))
            ctx.clip()
            // CSS angles run clockwise from "to top": 0 points up, 180 down.
            let radians = (angle - 90) * .pi / 180
            let r = shape.rect
            let cx = r.x + r.width / 2, cy = r.y + r.height / 2
            // Half the box's diagonal projected onto the gradient's axis, so
            // the run covers the whole shape at any angle.
            let half = (abs(cos(radians)) * r.width + abs(sin(radians)) * r.height) / 2
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: cx - cos(radians) * half, y: cy - sin(radians) * half),
                end: CGPoint(x: cx + cos(radians) * half, y: cy + sin(radians) * half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()

        case .radial(let center, let radius, let stops):
            guard let gradient = gradient(stops) else { return }
            ctx.saveGState()
            ctx.addPath(path(shape))
            ctx.clip()
            let r = shape.rect
            let c = CGPoint(x: r.x + r.width * center.x, y: r.y + r.height * center.y)
            // An ELLIPSE whose radii are fractions of each axis — matching the
            // web's `ellipse R% R%`, which is itself a correction: `circle R%`
            // is invalid CSS and silently dropped the gradient entirely.
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: CGFloat(r.width), y: CGFloat(r.height))
            ctx.drawRadialGradient(
                gradient,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: CGFloat(radius),
                options: [.drawsAfterEndLocation]
            )
            ctx.restoreGState()

        case .image(let url, let fit, let position, let opacity):
            ctx.saveGState()
            ctx.addPath(path(shape))
            ctx.clip()
            if opacity < 1 { ctx.setAlpha(CGFloat(opacity)) }
            drawImage(url: url, fit: fit, position: position, in: shape.rect, ctx: ctx)
            ctx.restoreGState()
        }
    }

    private func gradient(_ stops: [GradientStop]) -> CGGradient? {
        guard !stops.isEmpty else { return nil }
        let sorted = stops.sorted { $0.at < $1.at }
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: sorted.map { cg($0.color) } as CFArray,
            locations: sorted.map { CGFloat($0.at) }
        )
    }

    // MARK: - stroke

    private func draw(_ stroke: Stroke, in shape: RoundedRect, ctx: CGContext) {
        let w = stroke.width
        let uniform = w.top == w.right && w.right == w.bottom && w.bottom == w.left
        guard uniform, w.top > 0 else {
            // Per-edge widths need four separate paths, and nothing in the
            // corpus asks for one. Drawing the max on all four edges would be a
            // plausible wrong answer, so draw nothing and let it be noticed.
            return
        }
        ctx.setStrokeColor(cg(stroke.color))
        ctx.setLineWidth(CGFloat(w.top))
        if let dash = stroke.dash {
            ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
        }
        // A stroke straddles its path, so an inside border has to be drawn on a
        // rect inset by half its width or half of it lands outside the box —
        // which is what `box-sizing: border-box` means and what the solver
        // already assumed when it took the width out of the content box.
        let half = w.top / 2
        let inset = stroke.align == .inside ? half : -half
        let r = shape.rect
        ctx.addPath(path(RoundedRect(
            rect: Rect(
                x: r.x + inset, y: r.y + inset,
                width: r.width - 2 * inset, height: r.height - 2 * inset
            ),
            corners: Corners(
                topLeft: max(0, shape.corners.topLeft - inset),
                topRight: max(0, shape.corners.topRight - inset),
                bottomRight: max(0, shape.corners.bottomRight - inset),
                bottomLeft: max(0, shape.corners.bottomLeft - inset)
            )
        )))
        ctx.strokePath()
    }

    private func drawShadow(_ shadow: Shadow, shape: RoundedRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: CGFloat(shadow.x), height: CGFloat(shadow.y)),
            // CoreGraphics blur is a standard deviation where CSS is a
            // diameter; half is the conventional conversion and matches what
            // the two look like side by side.
            blur: CGFloat(shadow.blur / 2),
            color: cg(shadow.color)
        )
        let r = shape.rect
        let s = shadow.spread
        ctx.setFillColor(cg(shadow.color))
        ctx.addPath(path(RoundedRect(
            rect: Rect(x: r.x - s, y: r.y - s, width: r.width + 2 * s, height: r.height + 2 * s),
            corners: shape.corners
        )))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - backdrop

    /// A frosted panel: what has already been drawn under the node, blurred.
    ///
    /// Possible at all because the painter works strictly back to front — by
    /// the time an item is reached, everything behind it is in the buffer, so
    /// the "backdrop" is just the pixels that are already there. It reads them
    /// straight out of the bitmap rather than going through `makeImage()`,
    /// which would copy the whole screen for a 60pt panel.
    ///
    /// A BOX blur, three passes, which converges on a Gaussian and is
    /// deterministic to the bit — the property that matters here, because a
    /// golden compares exact pixels and `CIGaussianBlur` is free to change its
    /// kernel between OS releases. The radius conversion is the standard one:
    /// CSS blur is a Gaussian sigma, and a box of width `sigma * 3` repeated
    /// three times approximates it closely.
    ///
    /// Returns silently when the context is not a bitmap — on a real screen the
    /// host view uses the platform's own blur, and a painter drawing into a
    /// window layer has no pixels to read.
    private func drawBackdrop(blur radius: Double, shape: RoundedRect, ctx: CGContext) {
        guard radius > 0, let base = ctx.data, ctx.bitsPerPixel == 32 else { return }
        let device = ctx.convertToDeviceSpace(CGRect(
            x: shape.rect.x, y: shape.rect.y,
            width: shape.rect.width, height: shape.rect.height
        )).integral
        let x0 = max(0, Int(device.minX)), y0 = max(0, Int(device.minY))
        let x1 = min(ctx.width, Int(device.maxX)), y1 = min(ctx.height, Int(device.maxY))
        let w = x1 - x0, h = y1 - y0
        guard w > 1, h > 1 else { return }

        let rowBytes = ctx.bytesPerRow
        let buf = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = buf + (y0 + row) * rowBytes + x0 * 4
            pixels.withUnsafeMutableBytes { dst in
                _ = memcpy(dst.baseAddress! + row * w * 4, src, w * 4)
            }
        }

        // Device pixels, not points: the CTM already carries the device scale.
        let sigma = radius * Double(ctx.ctm.a)
        let box = max(1, Int((sigma * 3 * 0.5).rounded()))
        var scratch = pixels
        for _ in 0..<3 {
            boxBlur(&pixels, into: &scratch, width: w, height: h, radius: box, horizontal: true)
            swap(&pixels, &scratch)
            boxBlur(&pixels, into: &scratch, width: w, height: h, radius: box, horizontal: false)
            swap(&pixels, &scratch)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: ctx.bitmapInfo.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return }

        ctx.saveGState()
        ctx.addPath(path(shape))
        ctx.clip()
        let r = shape.rect
        ctx.translateBy(x: 0, y: CGFloat(r.y + r.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: r.x, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// One separable pass, using a running sum so cost is independent of radius.
    private func boxBlur(
        _ src: inout [UInt8], into dst: inout [UInt8],
        width: Int, height: Int, radius: Int, horizontal: Bool
    ) {
        let outer = horizontal ? height : width
        let inner = horizontal ? width : height
        let step = horizontal ? 4 : width * 4
        let lineStep = horizontal ? width * 4 : 4
        let window = Double(radius * 2 + 1)

        for line in 0..<outer {
            let origin = line * lineStep
            for channel in 0..<4 {
                var sum = 0.0
                // Seed the window, clamping at the edge so a border does not
                // darken — the alternative is treating outside as transparent,
                // which fades every panel's rim.
                for i in -radius...radius {
                    let c = min(max(i, 0), inner - 1)
                    sum += Double(src[origin + c * step + channel])
                }
                for i in 0..<inner {
                    dst[origin + i * step + channel] = UInt8(
                        max(0, min(255, (sum / window).rounded()))
                    )
                    let out = min(max(i - radius, 0), inner - 1)
                    let into = min(max(i + radius + 1, 0), inner - 1)
                    sum += Double(src[origin + into * step + channel])
                    sum -= Double(src[origin + out * step + channel])
                }
            }
        }
    }

    // MARK: - content

    private func draw(_ content: PaintContent, in item: PaintItem, ctx: CGContext) {
        switch content {
        case .image(let url, let fit, let position):
            ctx.saveGState()
            ctx.addPath(path(item.shape))
            ctx.clip()
            drawImage(url: url, fit: fit, position: position, in: item.frame, ctx: ctx)
            ctx.restoreGState()
        case .text(let run, let color, let align, let maxLines):
            drawText(
                run, color: color, align: align, maxLines: maxLines,
                in: item.contentBox, ctx: ctx
            )
        }
    }

    private func drawImage(
        url: String, fit: ImageFit, position: Point2D, in rect: Rect, ctx: CGContext
    ) {
        guard let image = images[url] else {
            // The frame is right even when the bytes are not here yet, so draw
            // the box and move on. A golden that silently drew nothing would
            // pass whether or not the image node was laid out at all.
            ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
            ctx.fill(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            return
        }
        let iw = Double(image.width), ih = Double(image.height)
        guard iw > 0, ih > 0 else { return }
        var w = rect.width, h = rect.height
        switch fit {
        case .fill:
            break
        case .cover:
            let s = max(rect.width / iw, rect.height / ih)
            w = iw * s
            h = ih * s
        case .contain, .tile:
            let s = min(rect.width / iw, rect.height / ih)
            w = iw * s
            h = ih * s
        }
        // `position` is the fraction of the OVERFLOW the image is shifted by —
        // 0.5 centres it, which is why it is a lerp and not a multiply.
        let x = rect.x + (rect.width - w) * position.x
        let y = rect.y + (rect.height - h) * position.y
        ctx.saveGState()
        // CoreGraphics draws images bottom-up; the rest of this file works in
        // top-down screen coordinates, so flip just this draw.
        ctx.translateBy(x: 0, y: CGFloat(y + h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: x, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawText(
        _ run: TextRunSpec, color: RGBA, align: TextAlign, maxLines: Int?,
        in rect: Rect, ctx: CGContext
    ) {
        var spec = run
        spec.maxWidth = rect.width
        let metrics = measurer.measure(spec)
        let lineBox = run.lineBox > 0 ? run.lineBox : (metrics.height / max(1, Double(metrics.lines.count)))
        let lines = maxLines.map { Array(metrics.lines.prefix($0)) } ?? metrics.lines

        for (i, line) in lines.enumerated() {
            let x: Double
            switch align {
            case .start: x = rect.x
            case .center: x = rect.x + (rect.width - line.width) / 2
            case .end: x = rect.x + rect.width - line.width
            }
            // The baseline sits inside the line box, not on it. CSS centres the
            // font's own box in the line box — half the leading above, half
            // below — so the baseline is that plus the ascent.
            let font = CoreTextMeasurer.font(size: run.fontSize, weight: run.fontWeight)
            let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
            let halfLeading = (lineBox - (ascent + descent)) / 2
            let baseline = rect.y + Double(i) * lineBox + halfLeading + ascent

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: CGFloat(baseline))
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: 0)
            let attributed = attributedLine(line.text, run: run, color: color)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            ctx.restoreGState()
        }
    }

    /// One laid-out line as an attributed string, spans and all.
    ///
    /// A line can straddle a span boundary — "€8.99" bold running into
    /// " / week" regular — so the attributes are rebuilt by walking the run's
    /// segments and taking the slice of each that this line covers.
    private func attributedLine(_ text: String, run: TextRunSpec, color: RGBA) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var remaining = Substring(text)
        for span in run.resolvedSpans {
            guard !remaining.isEmpty else { break }
            let take = min(span.text.count, remaining.count)
            // Segments are matched by LENGTH against the line's text rather than
            // by searching for the substring: a span can repeat, and finding the
            // wrong occurrence would restyle the wrong glyphs.
            let piece = String(remaining.prefix(take))
            remaining = remaining.dropFirst(take)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: CoreTextMeasurer.font(size: span.fontSize, weight: span.fontWeight),
                .foregroundColor: cg(span.color ?? color),
            ]
            if span.letterSpacing != 0 { attrs[.kern] = span.letterSpacing }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        if !remaining.isEmpty {
            out.append(NSAttributedString(string: String(remaining), attributes: [
                .font: CoreTextMeasurer.font(size: run.fontSize, weight: run.fontWeight),
                .foregroundColor: cg(color),
            ]))
        }
        return out
    }
}
