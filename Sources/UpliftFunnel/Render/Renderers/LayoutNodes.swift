import Foundation
import SwiftUI

// Layout containers (Spec v2 §3.1/§4), ported from `layout_nodes.dart`:
// stack, spacer, grid, scroll, divider, carousel.

// MARK: - stack (§4.1) — flexbox

@MainActor
func renderStack(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let direction = p["direction"].stringValue ?? "column"
    let gap = p["gap"].doubleValue ?? 0

    if direction == "overlay" {
        let childCtx = ctx
        return applyStyle(
            ZStack {
                ForEach(Array(n.children.enumerated()), id: \.offset) { _, child in
                    renderNode(child, childCtx)
                }
            },
            n.style, ctx)
    }

    let isRow = direction == "row"
    let axis: Axis = isRow ? .horizontal : .vertical
    let childCtx = ctx.withParentAxis(axis)
    let align = p["align"].stringValue
    let justify = p["justify"].stringValue ?? "start"
    let stretch = align == "stretch"

    let width = p["width"]
    let height = p["height"]
    // A block-level flex ROW fills its inline axis in CSS, so `justify` always
    // has free space to distribute; a column is content-sized on the block
    // axis, so vertical distribution still needs an explicit height (or a flex
    // spacer child). Only a row laid out in a column context is block-level —
    // a row nested inside another row is a flex ITEM and stays content-sized,
    // or it would greedily eat its siblings' width.
    let autoFillRow = isRow && justify != "start" && ctx.parentAxis == .vertical
    let mainAxisFilled = (isRow ? width : height).stringValue == "fill"
        || (isRow ? width : height).doubleValue != nil
        || autoFillRow

    // Whether justify spacers are needed: SwiftUI stacks hug content, so
    // space distribution only matters when the main axis has room.
    let needsJustify = justify != "start" && mainAxisFilled
        && !n.children.contains { greedyChild($0, isRow: isRow) }

    func renderedChild(_ child: PrimNode) -> AnyView {
        var view = renderNode(child, childCtx)
        // fill on the main axis = flex-grow 1 (§4.4).
        if child.type == "stack",
           child.props[isRow ? "width" : "height"].stringValue == "fill" {
            view = AnyView(view.frame(
                maxWidth: isRow ? .infinity : nil,
                maxHeight: isRow ? nil : .infinity))
        }
        if stretch {
            // CSS `align-items: stretch` fills the child's cross axis; the
            // CHILD's own justify positions its content inside that box. Now
            // that row texts hug (no .infinity frames), a hugging row child
            // would otherwise center inside the stretch frame — pin it per
            // its own justify instead.
            let alignment: Alignment
            if child.type == "stack" {
                alignment = stackFrameAlignment(
                    align: child.props["align"].stringValue,
                    justify: child.props["justify"].stringValue ?? "start",
                    isRow: (child.props["direction"].stringValue ?? "column") == "row")
            } else {
                alignment = .center
            }
            view = AnyView(view.frame(
                maxWidth: isRow ? nil : .infinity,
                maxHeight: isRow ? .infinity : nil,
                alignment: alignment))
        }
        return view
    }

    let children = n.children

    @ViewBuilder
    func content() -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            if needsJustify, justify == "between" || justify == "around" || justify == "evenly",
               index > 0 {
                Spacer(minLength: gap)
            }
            renderedChild(child)
        }
    }

    var flex: AnyView
    if isRow {
        flex = AnyView(HStack(
            alignment: verticalAlign(align), spacing: needsJustify ? nil : gap
        ) {
            if needsJustify, justify == "center" || justify == "end" || justify == "around" {
                Spacer(minLength: 0)
            }
            content()
            if needsJustify, justify == "center" || justify == "around" {
                Spacer(minLength: 0)
            }
        })
    } else {
        flex = AnyView(VStack(
            alignment: horizontalAlign(align), spacing: needsJustify ? nil : gap
        ) {
            if needsJustify, justify == "center" || justify == "end" || justify == "around" {
                Spacer(minLength: 0)
            }
            content()
            if needsJustify, justify == "center" || justify == "around" {
                Spacer(minLength: 0)
            }
        })
    }

    // Width/height on the stack itself: fill or fixed px.
    let wPx = width.stringValue == nil ? width.doubleValue : nil
    let hPx = height.stringValue == nil ? height.doubleValue : nil
    // A distributing row has to OCCUPY the space it distributes, or its
    // justify spacers collapse and the children pack at the leading edge
    // (two hugging texts with `justify: "between"` rendering as one run).
    let wFill = width.stringValue == "fill" || (autoFillRow && wPx == nil)
    let hFill = height.stringValue == "fill"
    if wFill || hFill {
        flex = AnyView(flex.frame(
            maxWidth: wFill ? .infinity : nil,
            maxHeight: hFill ? .infinity : nil,
            alignment: stackFrameAlignment(align: align, justify: justify, isRow: isRow)))
    }
    if wPx != nil || hPx != nil {
        flex = AnyView(flex.frame(width: wPx.map { CGFloat($0) },
                                  height: hPx.map { CGFloat($0) }))
    }

    // A stretch column with no explicit width fills its parent's cross axis
    // so children (buttons, pills) span full width — matches the reference.
    if !isRow, stretch, width.isNull {
        flex = AnyView(flex.frame(maxWidth: .infinity))
    }

    return applyStyle(flex, n.style, ctx)
}

private func greedyChild(_ c: PrimNode, isRow: Bool) -> Bool {
    if c.type == "spacer", let f = c.props["flex"].doubleValue, f > 0 { return true }
    if c.type == "stack",
       c.props[isRow ? "width" : "height"].stringValue == "fill" {
        return true
    }
    return false
}

private func horizontalAlign(_ align: String?) -> HorizontalAlignment {
    switch align {
    case "center": return .center
    case "end": return .trailing
    default: return .leading
    }
}

private func verticalAlign(_ align: String?) -> VerticalAlignment {
    switch align {
    case "center": return .center
    case "end": return .bottom
    case "stretch": return .center
    default: return .top
    }
}

/// When the stack fills an axis, un-justified content should still sit per
/// its declared alignment inside the expanded frame.
private func stackFrameAlignment(align: String?, justify: String, isRow: Bool) -> Alignment {
    let horizontal: HorizontalAlignment
    let vertical: VerticalAlignment
    if isRow {
        horizontal = justify == "center" ? .center : (justify == "end" ? .trailing : .leading)
        vertical = verticalAlign(align)
    } else {
        horizontal = horizontalAlign(align)
        vertical = justify == "center" ? .center : (justify == "end" ? .bottom : .top)
    }
    return Alignment(horizontal: horizontal, vertical: vertical)
}

// MARK: - spacer (§4.1)

@MainActor
func renderSpacer(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    if let flex = n.props["flex"].doubleValue, flex > 0 {
        return AnyView(Spacer(minLength: 0))
    }
    let size = n.props["size"].doubleValue ?? 0
    return AnyView(Color.clear.frame(width: size, height: size))
}

// MARK: - grid

/// grid → CSS `grid-template-columns: repeat(n, 1fr)` as a column of rows
/// with equal-width cells. Short final rows are padded with empty cells so
/// widths match full rows.
@MainActor
func renderGrid(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let columns = max(p["columns"].intValue ?? 2, 1)
    let gap = p["gap"].doubleValue ?? 0
    let aspect = p["aspect"].doubleValue
    let children = n.children
    let rowCount = (children.count + columns - 1) / columns

    func cell(_ index: Int) -> AnyView {
        guard index < children.count else { return AnyView(Color.clear) }
        var view = renderNode(children[index], ctx)
        if let aspect {
            view = AnyView(view.aspectRatio(aspect, contentMode: .fit))
        }
        return view
    }

    return applyStyle(
        VStack(spacing: gap) {
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(r * columns + c)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        },
        n.style, ctx)
}

// MARK: - scroll

@MainActor
func renderScrollNode(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let horizontal = n.props["direction"].stringValue == "horizontal"
    let childCtx = ctx.withParentAxis(horizontal ? .horizontal : .vertical)
    let children = n.children
    return applyStyle(
        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            if horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        renderNode(child, childCtx)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        renderNode(child, childCtx)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        },
        n.style, ctx)
}

// MARK: - divider

@MainActor
func renderDivider(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let p = n.props
    let thickness = p["thickness"].doubleValue ?? 1
    let color = ctx.color(p["color"].stringValue, fallback: ctx.border)
    let inset = p["inset"].doubleValue ?? 0
    return applyStyle(
        color.color
            .frame(height: thickness)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, inset),
        n.style, ctx)
}

// MARK: - carousel (§3.4)

@MainActor
func renderCarousel(_ n: PrimNode, _ ctx: RenderCtx) -> AnyView {
    let slides = (n.props["slides"].arrayValue ?? [])
        .filter { $0.objectValue != nil }
        .map { PrimNode(json: $0) }
    let indicator = n.props["indicator"].stringValue ?? "dots"
    return applyStyle(
        CarouselControl(
            slides: slides, ctx: ctx, indicator: indicator),
        n.style, ctx)
}

/// A horizontally paged carousel with a dots/dashes indicator tracking the
/// live page.
struct CarouselControl: View {
    let slides: [PrimNode]
    let ctx: RenderCtx
    let indicator: String

    @State private var page = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    renderNode(slide, ctx).tag(index)
                }
            }
            #if !os(macOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            // Height derives from the reference carousel (150-high slides).
            .frame(height: 150)

            if indicator != "none", slides.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<slides.count, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? ctx.primary.color : ctx.border.color)
                            .frame(width: indicator == "dashes" ? 16 : 7, height: 7)
                    }
                }
            }
        }
    }
}
