import XCTest

@testable import UpliftFunnel

/// How much room the top bar takes, and who decides.
///
/// This number is not decoration. The solver lays the document into
/// `screen height − safe area − chrome`, a `fill` child divides that box, and a
/// pinned footer resolves against its bottom — so a chrome height that is wrong
/// by 24pt moves every node on the screen and puts the footer 24pt off.
///
/// It WAS wrong by 24pt. iOS reserved a literal 44 for every screen; the web
/// has always reserved 44 only when the bar actually draws something and 20
/// when it does not. Nothing failed, because the two numbers lived in two files
/// in two languages and neither was asserted.
///
/// The cases below are the web's `chromeHeight` branches, transcribed. If that
/// function changes, this file has to change with it — which is the point: a
/// shared rule that neither side can quietly edit alone.
final class ChromeHeightTests: XCTestCase {
    private func height(_ bar: [String: Any]?, canGoBack: Bool = false) -> Double {
        TopBarChrome.height(for: bar, canGoBack: canGoBack)
    }

    func testAnEmptyBarReservesTwenty() {
        XCTAssertEqual(height(nil), 20)
        XCTAssertEqual(height([:]), 20)
    }

    func testACloseButtonMakesItFortyFour() {
        XCTAssertEqual(height(["close": true]), 44)
    }

    /// Back is shown whenever the session CAN go back — the screen has to opt
    /// OUT. iOS had this inverted, requiring an explicit `back: true`, so a
    /// flow that said nothing about it got a back button in the preview and
    /// none on the device.
    func testBackIsTheDefaultOnceThereIsSomewhereToGo() {
        XCTAssertEqual(height(nil, canGoBack: true), 44)
        XCTAssertEqual(height([:], canGoBack: true), 44)
        XCTAssertEqual(height(["back": false], canGoBack: true), 20, "an explicit opt-out was ignored")
        XCTAssertEqual(height(["back": true], canGoBack: false), 20, "there is nowhere to go back to")
    }

    func testASkipLabelCounts() {
        XCTAssertEqual(height(["skip": ["label": "Skip"]]), 44)
        // A skip object with no label draws nothing, so it reserves nothing.
        XCTAssertEqual(height(["skip": [:] as [String: Any]]), 20)
    }

    func testATitleCounts() {
        XCTAssertEqual(height(["title": "Your plan"]), 44)
    }

    /// The corpus, screen by screen — the numbers the recorded web baseline was
    /// laid out against. `wellness-onboarding` reserves 743 of an 844pt screen
    /// on its welcome screen and 719 on the one with a back button, and those
    /// 24pt are exactly this.
    func testTheCorpusScreens() {
        // welcome: no chrome at all, entry screen, nowhere to go back to.
        XCTAssertEqual(height(nil, canGoBack: false), 20)
        // name: second screen, so back is available and undeclared.
        XCTAssertEqual(height(nil, canGoBack: true), 44)
        // interior-paywall: a close button, and back suppressed.
        XCTAssertEqual(height(["close": true, "back": false], canGoBack: true), 44)
    }

    func testAffordanceAgreesWithHeight() {
        // The two are one decision; a height of 44 with nothing drawn in it is
        // a 24pt band of empty screen, and a 20 with a chevron in it clips.
        for bar: [String: Any]? in [
            nil, [:], ["close": true], ["title": "T"], ["skip": ["label": "S"]], ["back": false],
        ] {
            for canGoBack in [true, false] {
                let drawn = TopBarChrome.affordance(in: bar, canGoBack: canGoBack)
                XCTAssertEqual(
                    height(bar, canGoBack: canGoBack),
                    drawn ? 44 : 20,
                    "height and affordance disagree for \(String(describing: bar)) canGoBack=\(canGoBack)"
                )
            }
        }
    }
}
