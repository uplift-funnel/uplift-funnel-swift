import XCTest

@testable import UpliftFunnel

// Three schema additions that must behave identically here, in the Flutter SDK
// and in the web preview — a flow is authored once and rendered by all three.
// The Flutter counterpart is test/top_bar_and_pinning_test.dart.

// MARK: - pin_bottom on signin

@MainActor
final class SignInPinningTests: XCTestCase {
    func testSignInPinsLikeAButton() throws {
        // `buttons_bottom` only puts a flexible spacer above the provider
        // buttons, which stops holding them once content outgrows the screen.
        let root = PrimNode(
            json: try JSONValue.parse(
                """
                {"type":"stack","children":[
                  {"type":"text","props":{"value":"Body"}},
                  {"type":"signin","bind":{"save_to":"auth_provider"},
                   "props":{"providers":[{"provider":"apple"}],"pin_bottom":true}}
                ]}
                """))
        let (kept, pinned) = extractPinned(root)
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned[0].type, "signin")
        XCTAssertEqual(kept?.children.count, 1)
    }

    func testUnpinnedSignInStaysInTheBody() throws {
        let root = PrimNode(
            json: try JSONValue.parse(
                """
                {"type":"stack","children":[
                  {"type":"signin","bind":{"save_to":"auth_provider"},
                   "props":{"providers":[{"provider":"apple"}]}}
                ]}
                """))
        let (kept, pinned) = extractPinned(root)
        XCTAssertTrue(pinned.isEmpty)
        XCTAssertEqual(kept?.children.count, 1)
    }

    func testAPinnedButtonAndSignInBothReachTheFooter() throws {
        let root = PrimNode(
            json: try JSONValue.parse(
                """
                {"type":"stack","children":[
                  {"type":"signin","bind":{"save_to":"a"},
                   "props":{"providers":[{"provider":"apple"}],"pin_bottom":true}},
                  {"type":"button","props":{"label":"CTA","pin_bottom":true}}
                ]}
                """))
        let (_, pinned) = extractPinned(root)
        XCTAssertEqual(pinned.map(\.type), ["signin", "button"])
    }

    func testAnUnrelatedNodeIsNotPinnableEvenIfItSaysSo() throws {
        // Only the types carrying the schema's Pinnable mixin may pin; a stray
        // prop on a text node must not silently lift it into the footer.
        let root = PrimNode(
            json: try JSONValue.parse(
                """
                {"type":"stack","children":[
                  {"type":"text","props":{"value":"Hi","pin_bottom":true}}
                ]}
                """))
        let (kept, pinned) = extractPinned(root)
        XCTAssertTrue(pinned.isEmpty)
        XCTAssertEqual(kept?.children.count, 1)
    }
}

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

// MARK: - choice option description

@MainActor
final class ChoiceDescriptionTests: XCTestCase {
    private func option(_ json: String) throws -> ChoiceOptionData {
        var ctx = RenderCtx(
            theme: PrimTheme(json: .null), locale: "en", defaultLocale: "en",
            localizations: .object([:]), vars: [:])
        ctx.selections = [:]
        return ChoiceOptionData(try JSONValue.parse(json), ctx)
    }

    func testDescriptionResolves() throws {
        let opt = try option(
            #"{"value":"lose","label":"Lose weight","description":"Shed fat while keeping strength"}"#)
        XCTAssertEqual(opt.description, "Shed fat while keeping strength")
    }

    func testAbsentDescriptionIsEmptyNotNull() throws {
        // The renderers branch on `isEmpty`, so an absent description must not
        // read as the string "null".
        let opt = try option(#"{"value":"lose","label":"Lose weight"}"#)
        XCTAssertEqual(opt.description, "")
    }

    func testDescriptionResolvesThroughTheCatalog() throws {
        var ctx = RenderCtx(
            theme: PrimTheme(json: .null), locale: "tr", defaultLocale: "en",
            localizations: try JSONValue.parse(
                #"{"tr":{"opt.desc":"Kas koruyarak yağ yak"},"en":{"opt.desc":"Shed fat"}}"#),
            vars: [:])
        ctx.selections = [:]
        let opt = ChoiceOptionData(
            try JSONValue.parse(
                #"{"value":"lose","label":"Kilo ver","description":{"key":"opt.desc"}}"#),
            ctx)
        XCTAssertEqual(opt.description, "Kas koruyarak yağ yak")
    }
}
