import XCTest
@testable import UpliftLayout

/// Which image URLs a screen asks for, and the invariant that matters: the
/// string the host FETCHES has to be the string the paint LOOKS UP.
///
/// It was not. The host read `props.url` off the raw JSON as a `String`, while
/// the decoder stored the localized, interpolated result — so a URL carrying a
/// token was downloaded under its own braces and searched for under the
/// substituted value, and a localized `{ "key": … }` URL was not a string at
/// all and was dropped by the cast. Either way the image simply never arrived,
/// and the painter drew its grey placeholder with nothing to say about why.
final class ImageURLTests: XCTestCase {
    private func flow(_ root: [String: Any], localizations: [String: [String: String]] = [:]) -> [String: Any] {
        ["screens": [["root": root]], "default_locale": "en", "localizations": localizations]
    }

    /// Every URL the decoder put on a node, gathered from the tree it produced.
    /// This is the other side of the invariant: if the two walks ever disagree,
    /// this set and `imageURLs` stop matching.
    private func urlsOnTree(_ tree: LayoutNode) -> Set<String> {
        var out: Set<String> = []
        func walk(_ n: LayoutNode) {
            if let image = n.image, !image.url.isEmpty { out.insert(image.url) }
            n.children.forEach(walk)
        }
        walk(tree)
        return out
    }

    func testAPlainURLIsCollected() throws {
        let doc = flow([
            "type": "box",
            "children": [["type": "image", "props": ["url": "https://cdn.example/a.png"]]],
        ])
        XCTAssertEqual(
            LayoutDecoder.imageURLs(flow: doc, screenIndex: 0),
            ["https://cdn.example/a.png"]
        )
    }

    /// The bug, stated directly.
    func testAnInterpolatedURLIsCollectedInItsSUBSTITUTEDForm() throws {
        let doc = flow([
            "type": "box",
            "children": [["type": "image", "props": ["url": "https://cdn.example/{{avatar}}.png"]]],
        ])
        let input = LayoutInput(variables: ["avatar": "marlo"])
        let collected = LayoutDecoder.imageURLs(flow: doc, screenIndex: 0, input: input)
        XCTAssertEqual(collected, ["https://cdn.example/marlo.png"])

        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(flow: doc, screenIndex: 0, input: input))
        XCTAssertEqual(collected, urlsOnTree(tree), "fetch key and lookup key must be the same string")
    }

    /// `props.url` is a `LocalizedString` in the schema, so the object form is
    /// legal and the old `as? String` cast silently threw it away.
    func testALocalizedURLIsResolvedThroughTheCatalog() throws {
        let doc = flow(
            [
                "type": "box",
                "children": [["type": "image", "props": ["url": ["key": "hero.url"]]]],
            ],
            localizations: ["en": ["hero.url": "https://cdn.example/hero-en.jpg"]]
        )
        let collected = LayoutDecoder.imageURLs(flow: doc, screenIndex: 0)
        XCTAssertEqual(collected, ["https://cdn.example/hero-en.jpg"])

        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(flow: doc, screenIndex: 0, locale: "en"))
        XCTAssertEqual(collected, urlsOnTree(tree))
    }

    /// A token with nothing behind it leaves braces in the string. Fetching
    /// that is a guaranteed round-trip to a 404, so it is not collected.
    func testAnUnresolvedTokenIsNotFetched() {
        let doc = flow([
            "type": "box",
            "children": [["type": "image", "props": ["url": "https://cdn.example/{{missing}}.png"]]],
        ])
        XCTAssertTrue(LayoutDecoder.imageURLs(flow: doc, screenIndex: 0).isEmpty)
    }

    func testAnImagePaintIsCollected() {
        let doc = flow([
            "type": "box",
            "style": ["fill": ["kind": "image", "url": "https://cdn.example/bg.jpg"]],
        ])
        XCTAssertEqual(
            LayoutDecoder.imageURLs(flow: doc, screenIndex: 0),
            ["https://cdn.example/bg.jpg"]
        )
    }

    func testAURLScopedFromItsProductResolves() {
        let doc = flow([
            "type": "box",
            "behavior": ["product": ["ref": "yearly"]],
            "children": [["type": "image", "props": ["url": "https://cdn.example/{{product.period}}.png"]]],
        ])
        XCTAssertEqual(
            LayoutDecoder.imageURLs(
                flow: doc, screenIndex: 0,
                input: LayoutInput(products: ["yearly": ["period": "year"]])
            ),
            ["https://cdn.example/year.png"]
        )
    }

    func testAScreenWithNoImagesAsksForNothing() {
        let doc = flow(["type": "box", "children": [["type": "text", "props": ["value": "hi"]]]])
        XCTAssertTrue(LayoutDecoder.imageURLs(flow: doc, screenIndex: 0).isEmpty)
    }
}
