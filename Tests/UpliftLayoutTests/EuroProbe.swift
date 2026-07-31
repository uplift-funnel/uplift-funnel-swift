import CoreText
import XCTest
@testable import UpliftFunnel
@testable import UpliftLayout

final class EuroProbe: XCTestCase {
    /// Does applying the wght variation reset the optical-size axis?
    func testOpticalSize() {
        for size in [15.0, 19.0, 22.0, 26.0, 34.0] {
            let mine = CoreTextMeasurer.font(size: size, weight: 400)
            let plain = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)!
            func w(_ f: CTFont, _ s: String) -> Double {
                CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(
                        NSAttributedString(string: s, attributes: [.font: f])
                    ), nil, nil, nil
                )
            }
            print(String(
                format: "size %4.0f  €: mine %7.4f plain %7.4f   'Weekly': mine %7.4f plain %7.4f\n"
                    + "            mine=%@\n            plain=%@",
                size, w(mine, "€"), w(plain, "€"), w(mine, "Weekly"), w(plain, "Weekly"),
                CTFontCopyPostScriptName(mine) as String,
                CTFontCopyPostScriptName(plain) as String
            ))
        }
    }

    /// If opsz is the cause, pinning it to the point size should land on
    /// Chromium's 61.296875 for "€8.99" at 22/700.
    func testOpszSweep() {
        let base = CTFontCreateUIFontForLanguage(.system, 22, nil)!
        let wght = 0x77676874 as CFNumber
        let opsz = 0x6F70737A as CFNumber
        for candidate in [16.0, 17.0, 19.0, 20.0, 22.0, 24.0, 96.0] {
            let d = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base),
                [kCTFontVariationAttribute: [wght: 700, opsz: candidate]] as CFDictionary
            )
            let f = CTFontCreateWithFontDescriptor(d, 22, nil)
            let w = CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: "€8.99", attributes: [.font: f])
                ), nil, nil, nil
            )
            print(String(format: "opsz %5.1f  €8.99 = %9.5f  (want 61.29688)  %@",
                         candidate, w, CTFontCopyPostScriptName(f) as String))
        }
    }

    /// What produces Chromium's 61.296875 for "€8.99" at 22/700?
    func testFaceSweep() {
        func w(_ f: CTFont, _ s: String, extra: [NSAttributedString.Key: Any] = [:]) -> Double {
            var a: [NSAttributedString.Key: Any] = [.font: f]
            a.merge(extra) { _, b in b }
            return CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a)),
                nil, nil, nil
            )
        }
        var candidates: [(String, CTFont)] = []
        for name in [".SFNS-Bold", ".SFNSText-Bold", ".SFNSDisplay-Bold", "SFProText-Bold",
                     "SFProDisplay-Bold", "Helvetica-Bold", "Arial-BoldMT", "HelveticaNeue-Bold"] {
            let f = CTFontCreateWithName(name as CFString, 22, nil)
            candidates.append((name, f))
        }
        // The named UI instance, via symbolic traits rather than the axis.
        let ui = CTFontCreateUIFontForLanguage(.system, 22, nil)!
        if let boldTrait = CTFontCreateCopyWithSymbolicTraits(ui, 22, nil, .traitBold, .traitBold) {
            candidates.append(("system+traitBold", boldTrait))
        }
        candidates.append(("mine(axis 700)", CoreTextMeasurer.font(size: 22, weight: 700)))

        for (name, f) in candidates {
            print(String(
                format: "%-20@ €8.99 %9.5f  € %8.5f  8.99 %9.5f  actual=%@",
                name, w(f, "€8.99"), w(f, "€"), w(f, "8.99"),
                CTFontCopyPostScriptName(f) as String
            ))
        }
        // Kerning forced on, in case the pair is meant to close up.
        let mine = CoreTextMeasurer.font(size: 22, weight: 700)
        print(String(format: "kern=0 (off)         €8.99 %9.5f", w(mine, "€8.99", extra: [.kern: 0])))
    }

    func testProbe() {
        for (text, size, weight, want) in [
            ("€8.99", 22.0, 700, 61.296875),
            ("€22.99", 22.0, 700, 74.078125),
            ("8.99", 22.0, 700, 0.0),
            ("€", 22.0, 700, 0.0),
        ] {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: CoreTextMeasurer.font(size: size, weight: weight),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attrs)
            )
            var faces: [String] = []
            for case let run as CTRun in (CTLineGetGlyphRuns(line) as NSArray) {
                let a = CTRunGetAttributes(run) as NSDictionary
                guard let f = a[kCTFontAttributeName as String] else { continue }
                let n = CTRunGetGlyphCount(run)
                faces.append("\(CTFontCopyPostScriptName(f as! CTFont) as String)×\(n)")
            }
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            print(String(
                format: "%@  want %8.4f  got %8.4f  delta %7.4f  %@",
                text, want, w, w - want, faces.joined(separator: " + ")
            ))
        }
    }
}
