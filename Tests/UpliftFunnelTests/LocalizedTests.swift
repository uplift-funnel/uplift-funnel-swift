import XCTest
@testable import UpliftFunnel

final class LocalizedTests: XCTestCase {
    private func render(_ template: String, _ vars: [String: String]) -> String {
        resolveString(
            .string(template), locale: "en", localizations: .object([:]),
            defaultLocale: "en", vars: vars)
    }

    // Port of interpolation_test.dart — `{{var}}` substitution, including
    // the dotted product tokens the SDK injects at session start.

    func testSubstitutesPlainVariable() {
        XCTAssertEqual(render("Hi {{name}}!", ["name": "Ada"]), "Hi Ada!")
    }

    func testSubstitutesDottedProductToken() {
        XCTAssertEqual(
            render("Just {{price.yearly_pro}} a year", ["price.yearly_pro": "₺899,99"]),
            "Just ₺899,99 a year")
    }

    func testSubstitutesSeveralTokens() {
        XCTAssertEqual(
            render("{{price.monthly}} or {{price.yearly}}", [
                "price.monthly": "$9.99", "price.yearly": "$99.99",
            ]),
            "$9.99 or $99.99")
    }

    func testToleratesWhitespaceInsideBraces() {
        XCTAssertEqual(render("{{  goal  }}", ["goal": "calm"]), "calm")
    }

    func testUnresolvedTokenRendersEmpty() {
        XCTAssertEqual(render("Goal: {{goal}}", [:]), "Goal: ")
    }

    func testTextWithoutTokensUntouched() {
        XCTAssertEqual(render("No tokens here", ["goal": "x"]), "No tokens here")
    }

    // Locale resolution: resolve-then-interpolate with fallback chain.

    private let catalog: JSONValue = [
        "en": ["greeting": "Hello {{name}}"],
        "tr": ["greeting": "Merhaba {{name}}"],
    ]

    func testKeyResolvesInActiveLocale() {
        let result = resolveString(
            ["key": "greeting"], locale: "tr", localizations: catalog,
            defaultLocale: "en", vars: ["name": "Ada"])
        XCTAssertEqual(result, "Merhaba Ada")
    }

    func testKeyFallsBackToDefaultLocale() {
        let result = resolveString(
            ["key": "greeting"], locale: "de", localizations: catalog,
            defaultLocale: "en", vars: ["name": "Ada"])
        XCTAssertEqual(result, "Hello Ada")
    }

    func testMissingKeyShowsRawKey() {
        let result = resolveString(
            ["key": "missing_key"], locale: "en", localizations: catalog,
            defaultLocale: "en", vars: [:])
        XCTAssertEqual(result, "missing_key")
    }

    func testNonStringNonKeyRendersEmpty() {
        XCTAssertEqual(
            resolveString(
                .number(42), locale: "en", localizations: .object([:]),
                defaultLocale: "en", vars: [:]),
            "")
    }

    // The markdown action-link tests that used to close this file went with
    // Markdown.swift. v3 puts an action on a SPAN (`span.action`) rather than
    // parsing one out of a link href, and the web renderer's own `markdownLite`
    // is likewise no longer called from anywhere.
}
