import XCTest
@testable import UpliftLayout

/// The two things the acceptance corpus structurally cannot check.
///
/// Both were found by writing the TypeScript port and reading the two
/// implementations side by side, not by a failing test — because no test could
/// fail. Every role-bearing node in both fixtures also sets an explicit `size`,
/// so the ramp's numbers were never consulted; and `first_name` is either
/// absent or set, so an empty interpolation never happened. Synthetic documents
/// are the only way to reach either, which is why these are hand-built rather
/// than driven from the corpus.
final class RampAndTokenTests: XCTestCase {
    private func run(_ node: [String: Any], input: LayoutInput = LayoutInput()) throws -> TextRunSpec {
        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(
            flow: ["screens": [["root": node]]], screenIndex: 0, input: input
        ))
        return try XCTUnwrap(tree.text)
    }

    // MARK: - the ramp

    /// Every role, against PRIMITIVE_SPEC §4.
    ///
    /// The numbers are copied from the spec table, not from this decoder — a
    /// test that read the implementation would have passed against the wrong
    /// ramp for as long as it existed.
    func testEveryRoleMatchesTheNormativeTable() throws {
        let spec: [String: (size: Double, lineHeight: Double, weight: Int)] = [
            "display": (34, 1.1, 700),
            "title": (26, 1.15, 700),
            "subtitle": (19, 1.3, 500),
            "body": (16, 1.45, 400),
            "caption": (13, 1.4, 400),
            "label": (14, 1.2, 500),
        ]
        for (role, want) in spec {
            let got = try run([
                "type": "text",
                "props": ["value": "Ag"],
                "style": ["text": ["role": role]],
            ])
            XCTAssertEqual(got.fontSize, want.size, accuracy: 0.0001, "\(role) size")
            XCTAssertEqual(got.lineHeight ?? 0, want.lineHeight, accuracy: 0.0001, "\(role) line height")
            XCTAssertEqual(got.fontWeight, want.weight, "\(role) weight")
        }
    }

    /// An unknown role falls back to body rather than to nothing.
    func testAnUnknownRoleFallsBackToBody() throws {
        let got = try run([
            "type": "text", "props": ["value": "Ag"],
            "style": ["text": ["role": "shout"]],
        ])
        XCTAssertEqual(got.fontSize, 16)
    }

    // MARK: - interpolation

    /// An unresolved token keeps its braces, because the braces are measured.
    func testAnUnresolvedTokenStaysLiteral() throws {
        let got = try run(["type": "text", "props": ["value": "Hi {{first_name}}!"]])
        XCTAssertEqual(got.text, "Hi {{first_name}}!")
    }

    /// So does one whose value is empty.
    ///
    /// This is the case the corpus never reaches and the one that was wrong: an
    /// answered-but-blank variable used to substitute nothing, shortening the
    /// line the browser lays out at full length.
    func testAnEmptyValueAlsoStaysLiteral() throws {
        let got = try run(
            ["type": "text", "props": ["value": "Hi {{first_name}}!"]],
            input: LayoutInput(variables: ["first_name": ""])
        )
        XCTAssertEqual(got.text, "Hi {{first_name}}!")
    }

    func testAResolvedTokenSubstitutes() throws {
        let got = try run(
            ["type": "text", "props": ["value": "Hi {{first_name}}!"]],
            input: LayoutInput(variables: ["first_name": "Alex"])
        )
        XCTAssertEqual(got.text, "Hi Alex!")
    }

    /// A multi-select reads as a list, not as its JSON.
    func testAnArrayValueReadsAsAList() throws {
        let got = try run(
            ["type": "text", "props": ["value": "You picked {{areas}}."]],
            input: LayoutInput(variables: ["areas": #"["sleep","stress"]"#])
        )
        XCTAssertEqual(got.text, "You picked sleep, stress.")
    }

    /// Several tokens in one string, and whitespace inside the braces.
    func testSeveralTokensAndLooseBraces() throws {
        let got = try run(
            ["type": "text", "props": ["value": "{{a}} and {{ b }} and {{c}}"]],
            input: LayoutInput(variables: ["a": "one", "b": "two"])
        )
        XCTAssertEqual(got.text, "one and two and {{c}}")
    }
}
