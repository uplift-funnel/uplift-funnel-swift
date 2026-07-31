import XCTest
@testable import UpliftLayout

/// The layout grid.
///
/// Every number in the web baseline lands on a sixty-fourth of a point, because
/// Chromium stores lengths as fixed-point `LayoutUnit`s and floors on
/// conversion. `lu` reproduces that, and these cases are taken from the real
/// dump in `apps/dashboard/tests/layout-baseline/` rather than invented.
final class GeometryTests: XCTestCase {
    func testQuantisesToSixtyFourths() {
        // A card top and a line width, both straight out of web-01.
        XCTAssertEqual(lu(413.046875), 413.046875)
        XCTAssertEqual(lu(94.453125), 94.453125)
        // Anything between two grid points floors to the lower one.
        XCTAssertEqual(lu(413.05), 413.046875)
        XCTAssertEqual(lu(94.46), 94.453125)
    }

    func testFloorsRatherThanRounds() {
        // The distinction matters: rounding would put 0.9999 on the next grid
        // point up, and Chromium does not.
        XCTAssertEqual(lu(0.9999), 0.984375)   // 63/64, not 1
        XCTAssertEqual(lu(1.0), 1.0)
        XCTAssertEqual(lu(-0.5), -0.5)
        XCTAssertEqual(lu(-0.501), -0.515625)  // floors away from zero
    }

    func testDriftIsWhyThisExists() {
        // Ten stacked lines of an unquantised height drift an eighth of a point
        // — enough to move the eleventh child visibly.
        let unrounded = 23.2
        let stacked = (0..<10).reduce(0.0) { acc, _ in acc + unrounded }
        let quantised = (0..<10).reduce(0.0) { acc, _ in acc + lu(unrounded) }
        XCTAssertEqual(lu(unrounded), 23.1875)
        XCTAssertEqual(stacked - quantised, 0.125, accuracy: 1e-9)
    }

    func testEdgesAndRects() {
        let e = Edges(top: 24, right: 20, bottom: 24, left: 20)
        XCTAssertEqual(e.horizontal, 40)
        XCTAssertEqual(e.vertical, 48)
        let r = Rect(x: 20, y: 324, width: 350, height: 73)
        XCTAssertEqual(r.maxX, 370)
        XCTAssertEqual(r.maxY, 397)
    }
}
