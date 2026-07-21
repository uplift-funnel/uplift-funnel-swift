import XCTest
@testable import UpliftFunnel

final class CssStyleTests: XCTestCase {
    func testHexForms() {
        XCTAssertEqual(parseCssColor("#16A34A"), RGBAColor(hex: 0x16A34A))
        XCTAssertEqual(parseCssColor("16A34A"), RGBAColor(hex: 0x16A34A))
        XCTAssertEqual(parseCssColor("#fff"), RGBAColor(hex: 0xFFFFFF))
        // Schema byte order is RRGGBBAA.
        let withAlpha = parseCssColor("#16A34A80")
        XCTAssertEqual(withAlpha?.r ?? 0, 0x16 / 255.0, accuracy: 0.001)
        XCTAssertEqual(withAlpha?.a ?? 0, 0x80 / 255.0, accuracy: 0.001)
        XCTAssertNil(parseCssColor("#12345"))
        XCTAssertNil(parseCssColor("not-a-color"))
        XCTAssertNil(parseCssColor(""))
    }

    func testRgbForms() {
        XCTAssertEqual(parseCssColor("rgb(255, 0, 0)"), RGBAColor(byteR: 255, byteG: 0, byteB: 0))
        let half = parseCssColor("rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(half?.a ?? 0, 0.5, accuracy: 0.01)
        let percent = parseCssColor("rgba(10, 20, 30, 50%)")
        XCTAssertEqual(percent?.a ?? 0, 0.5, accuracy: 0.01)
        // Out-of-range channels clamp.
        XCTAssertEqual(parseCssColor("rgb(300, 0, 0)")?.r, 1)
    }

    func testSolidBackground() {
        guard case .solid(let color)? = CssBackground.parse("#ff0000") else {
            return XCTFail("expected solid")
        }
        XCTAssertEqual(color, RGBAColor(hex: 0xFF0000))
    }

    func testLinearGradientAngleAndKeywords() {
        guard case .linearGradient(let angle, let colors, let stops)? =
                CssBackground.parse("linear-gradient(90deg, #000, #fff)") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(angle, 90)
        XCTAssertEqual(colors.count, 2)
        XCTAssertNil(stops)

        guard case .linearGradient(let angle2, _, _)? =
                CssBackground.parse("linear-gradient(to top right, #000, #fff)") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(angle2, 45)

        // Default angle: to bottom (180).
        guard case .linearGradient(let angle3, _, _)? =
                CssBackground.parse("linear-gradient(#000, #fff)") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(angle3, 180)
    }

    func testGradientStopInterpolation() {
        // Middle stop missing → interpolated; ends default to 0/1.
        guard case .linearGradient(_, _, let stops)? = CssBackground.parse(
            "linear-gradient(90deg, #000 0%, #444, #fff 100%)") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(stops!, [0, 0.5, 1])

        // Non-decreasing enforcement.
        guard case .linearGradient(_, _, let stops2)? = CssBackground.parse(
            "linear-gradient(90deg, #000 60%, #444 20%, #fff 100%)") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(stops2!, [0.6, 0.6, 1])
    }

    func testGradientWithRgbaStops() {
        guard case .linearGradient(_, let colors, _)? = CssBackground.parse(
            "linear-gradient(180deg, rgba(0,0,0,0.05), rgba(0,0,0,0.55))") else {
            return XCTFail("expected gradient")
        }
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[1].a, 0.55, accuracy: 0.01)
    }

    func testRepresentativeColor() {
        XCTAssertEqual(representativeColor("#ff0000"), RGBAColor(hex: 0xFF0000))
        XCTAssertEqual(
            representativeColor("linear-gradient(90deg, #000, #fff)"),
            RGBAColor(hex: 0x000000))
        XCTAssertEqual(
            representativeColor("linear-gradient(90deg, #000, #fff)", last: true),
            RGBAColor(hex: 0xFFFFFF))
        XCTAssertNil(representativeColor("nope"))
    }

    func testFontFamilyAliases() {
        XCTAssertEqual(resolveFontFamilyAlias(nil), .system)
        XCTAssertEqual(resolveFontFamilyAlias("system"), .system)
        XCTAssertEqual(resolveFontFamilyAlias("sans"), .system)
        XCTAssertEqual(resolveFontFamilyAlias("display"), .system)
        XCTAssertEqual(resolveFontFamilyAlias("serif"), .serif)
        XCTAssertEqual(resolveFontFamilyAlias("mono"), .mono)
        XCTAssertEqual(resolveFontFamilyAlias("Inter"), .custom("Inter"))
    }

    func testIsLight() {
        XCTAssertTrue(RGBAColor.white.isLight)
        XCTAssertFalse(RGBAColor.black.isLight)
        XCTAssertFalse(RGBAColor(hex: 0x16A34A).isLight, "primary green is dark enough for white text")
    }
}
