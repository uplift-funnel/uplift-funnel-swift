import Foundation

/// The document's `style` group → a `PaintStyle`.
///
/// Split from `Decode.swift` because the two answer different questions and
/// fail differently: a layout decode bug moves a box, a paint decode bug
/// recolours one, and keeping them in separate files keeps a failure's blast
/// radius readable. Both are driven from the same merged style dictionary, so
/// a state delta still resolves once.
///
/// Every default here is the web renderer's, and where it looks arbitrary it
/// is quoted from `render/css.ts` rather than chosen.
extension LayoutDecoder {
    static func paintStyle(_ style: [String: Any]?, tokens: [String: String]) -> PaintStyle {
        guard let style else { return .none }
        var out = PaintStyle()
        out.fill = paint(style["fill"], tokens: tokens)
        out.stroke = stroke(style["stroke"] as? [String: Any], tokens: tokens)
        out.corners = corners(style["corner"])
        out.shadows = shadows(style["shadow"] as? [[String: Any]], tokens: tokens)
        if let o = dbl(style["opacity"]) { out.opacity = o }
        out.transform = transform(style["transform"] as? [String: Any])
        out.backdropBlur = dbl(style["backdropBlur"])
        return out
    }

    // MARK: - fill

    static func paint(_ raw: Any?, tokens: [String: String]) -> Paint? {
        // A bare string is a colour — a token or a literal.
        if let s = raw as? String {
            return RGBA.parse(s, tokens: tokens).map(Paint.flat)
        }
        guard let d = raw as? [String: Any], let kind = d["kind"] as? String else { return nil }
        switch kind {
        case "linear":
            // 180 is the CSS default: top to bottom.
            return .linear(angle: dbl(d["angle"]) ?? 180, stops: stops(d["stops"], tokens: tokens))
        case "radial":
            let c = (d["center"] as? [NSNumber])?.map(\.doubleValue) ?? [0.5, 0.5]
            return .radial(
                center: Point2D(x: c.first ?? 0.5, y: c.count > 1 ? c[1] : 0.5),
                radius: dbl(d["radius"]) ?? 0.5,
                stops: stops(d["stops"], tokens: tokens)
            )
        case "image":
            let p = (d["position"] as? [NSNumber])?.map(\.doubleValue) ?? [0.5, 0.5]
            return .image(
                url: d["url"] as? String ?? "",
                fit: (d["fit"] as? String).flatMap(ImageFit.init(rawValue:)) ?? .cover,
                position: Point2D(x: p.first ?? 0.5, y: p.count > 1 ? p[1] : 0.5),
                opacity: dbl(d["opacity"]) ?? 1
            )
        default:
            return nil
        }
    }

    private static func stops(_ raw: Any?, tokens: [String: String]) -> [GradientStop] {
        ((raw as? [[String: Any]]) ?? []).compactMap { s in
            guard let c = RGBA.parse(s["color"] as? String, tokens: tokens) else { return nil }
            return GradientStop(color: c, at: dbl(s["at"]) ?? 0)
        }
    }

    // MARK: - stroke

    static func stroke(_ raw: [String: Any]?, tokens: [String: String]) -> Stroke? {
        guard let raw, let color = RGBA.parse(raw["color"] as? String, tokens: tokens) else {
            return nil
        }
        let width: Edges
        if let per = (raw["width"] as? [NSNumber])?.map(\.doubleValue), per.count == 4 {
            width = Edges(top: per[0], right: per[1], bottom: per[2], left: per[3])
        } else {
            let w = dbl(raw["width"]) ?? 1
            width = Edges(top: w, right: w, bottom: w, left: w)
        }
        // "dashed" and "dotted" are the CSS names; the numbers are the pattern
        // the placeholder border has always used.
        let dash: [Double]?
        switch raw["style"] as? String {
        case "dashed": dash = [5, 4]
        case "dotted": dash = [1, 3]
        default: dash = nil
        }
        return Stroke(
            color: color,
            width: width,
            align: (raw["align"] as? String).flatMap(StrokeAlign.init(rawValue:)) ?? .inside,
            dash: dash
        )
    }

    // MARK: - the rest

    static func corners(_ raw: Any?) -> Corners {
        if let per = (raw as? [NSNumber])?.map(\.doubleValue), per.count == 4 {
            return Corners(
                topLeft: per[0], topRight: per[1], bottomRight: per[2], bottomLeft: per[3]
            )
        }
        return Corners(dbl(raw) ?? 0)
    }

    static func shadows(_ raw: [[String: Any]]?, tokens: [String: String]) -> [Shadow] {
        (raw ?? []).map { s in
            Shadow(
                x: dbl(s["x"]) ?? 0,
                y: dbl(s["y"]) ?? 0,
                blur: dbl(s["blur"]) ?? 0,
                spread: dbl(s["spread"]) ?? 0,
                // The web's default when a shadow names no colour.
                color: RGBA.parse(s["color"] as? String, tokens: tokens)
                    ?? RGBA(r: 0, g: 0, b: 0, a: 0x26 / 255),
                inset: (s["inset"] as? Bool) ?? false
            )
        }
    }

    static func transform(_ raw: [String: Any]?) -> Transform2D {
        guard let raw else { return .identity }
        let t = (raw["translate"] as? [NSNumber])?.map(\.doubleValue) ?? []
        return Transform2D(
            translate: Point2D(x: t.first ?? 0, y: t.count > 1 ? t[1] : 0),
            rotate: dbl(raw["rotate"]) ?? 0,
            scale: dbl(raw["scale"]) ?? 1
        )
    }
}
