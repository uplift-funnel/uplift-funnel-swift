import XCTest

@testable import UpliftFunnel

/// What the solver is handed as its viewport.
///
/// The bottom inset was missing here for two releases, and no test failed —
/// because the arithmetic was a subexpression inside a SwiftUI view body, where
/// nothing could call it. The symptom reached devices instead: `SafeArea.bottom`
/// was declared and never read, so the body ran to the physical bottom of the
/// display, and a footer authored 24pt above the bottom landed inside the 34pt
/// home-indicator band. The dashboard preview reserved the inset all along, so
/// the author saw a footer clear of it and the user did not.
final class ScreenBoxTests: XCTestCase {
    /// iPhone 16 / 15 / 14 Pro: 852pt tall, 59pt top inset, 34pt bottom.
    func testReservesBothInsetsAndTheChrome() {
        XCTAssertEqual(
            ScreenBox.bodyHeight(display: 852, safeTop: 59, safeBottom: 34, chrome: 44),
            715)
    }

    /// The notch generation: 844pt tall, 47pt top, same 34pt bottom.
    func testNotchDevice() {
        XCTAssertEqual(
            ScreenBox.bodyHeight(display: 844, safeTop: 47, safeBottom: 34, chrome: 44),
            719)
    }

    /// A home-button device has no bottom inset, and the body reaches the edge.
    func testNoBottomInsetGivesTheWholeBody() {
        XCTAssertEqual(
            ScreenBox.bodyHeight(display: 667, safeTop: 20, safeBottom: 0, chrome: 20),
            627)
    }

    /// The regression itself, stated as a difference: reserving the bottom
    /// inset has to take exactly that inset out of the body, no more.
    func testTheBottomInsetIsTheWholeDifference() {
        let reserved = ScreenBox.bodyHeight(
            display: 852, safeTop: 59, safeBottom: 34, chrome: 44)
        let unreserved = ScreenBox.bodyHeight(
            display: 852, safeTop: 59, safeBottom: 0, chrome: 44)
        XCTAssertEqual(unreserved - reserved, 34)
    }

    /// A viewport with a negative height is one nothing can be placed in.
    func testClampsRatherThanGoingNegative() {
        XCTAssertEqual(
            ScreenBox.bodyHeight(display: 80, safeTop: 59, safeBottom: 34, chrome: 44),
            0)
    }
}
