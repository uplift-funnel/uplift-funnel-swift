import XCTest
@testable import UpliftFunnel

// `top_bar.progress` normalization.
//
// The sign-in pinning and choice-description suites that used to live here went
// with the v2 renderer: pinning is the SOLVER's job now (`self.position:
// fixed`, checked against Chromium's own frames in LayoutParityTests) and a
// choice is composed boxes rather than a node type with option data.

// MARK: - top_bar.progress

/// Mirrors the ChromeBar's own normalization. Kept as a free function here so
/// the union handling is asserted without standing up SwiftUI.
private func progressSpec(_ topBar: JSONValue) -> JSONValue {
    let raw = topBar["progress"]
    if let style = raw.stringValue { return .object(["style": .string(style)]) }
    return raw
}

@MainActor
final class ProgressSpecTests: XCTestCase {
    func testBareStyleStringLifts() throws {
        let bar = try JSONValue.parse(#"{"progress":"dots"}"#)
        XCTAssertEqual(progressSpec(bar)["style"].stringValue, "dots")
    }

    func testObjectFormPassesThrough() throws {
        let bar = try JSONValue.parse(
            #"{"progress":{"style":"bar","color":"primary","thickness":8}}"#)
        let spec = progressSpec(bar)
        XCTAssertEqual(spec["style"].stringValue, "bar")
        XCTAssertEqual(spec["color"].stringValue, "primary")
        XCTAssertEqual(spec["thickness"].doubleValue, 8)
    }

    func testAbsentProgressYieldsNoStyle() throws {
        let bar = try JSONValue.parse(#"{"close":true}"#)
        XCTAssertNil(progressSpec(bar)["style"].stringValue)
    }

    func testOverridesAreReadAsIntegers() throws {
        // The whole point: index/total are derived from the screen's position,
        // which is wrong on a branch or a resumed onboarding.
        let bar = try JSONValue.parse(
            #"{"progress":{"style":"numbered","index_override":2,"total_override":9}}"#)
        let spec = progressSpec(bar)
        XCTAssertEqual(spec["index_override"].intValue, 2)
        XCTAssertEqual(spec["total_override"].intValue, 9)
    }

    func testControlOverridesParse() throws {
        // ##"..."## because the hex colour contains `"#`, which closes a
        // single-pound raw string.
        let bar = try JSONValue.parse(
            ##"{"controls":{"color":"#e11d48","back_icon":"←","close_icon":"⨯","size":22}}"##)
        XCTAssertEqual(bar["controls"]["back_icon"].stringValue, "←")
        XCTAssertEqual(bar["controls"]["close_icon"].stringValue, "⨯")
        XCTAssertEqual(bar["controls"]["size"].doubleValue, 22)
        XCTAssertEqual(bar["controls"]["color"].stringValue, "#e11d48")
    }
}
