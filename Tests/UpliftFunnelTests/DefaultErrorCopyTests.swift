import XCTest
@testable import UpliftFunnel

// What the fallback error screen says.
//
// The screen this covers shipped unreadable: it painted no background of its
// own, so over a host window that was black — with a colour scheme resolving
// `.primary` to black — the message rendered black on black. Three lines of
// text, correct and invisible, above a Retry button. The background fix is a
// modifier and is verified by looking at it; what is worth holding here is the
// copy, because the reason the screen exists is that somebody reads it and
// learns what to change.

final class DefaultErrorCopyTests: XCTestCase {
    private func view(_ error: Error) -> DefaultErrorView {
        DefaultErrorView(error: error, retry: {})
    }

    private func fetchError(
        _ kind: FlowFetchError.Kind, status: Int? = nil
    ) -> FlowFetchError {
        FlowFetchError(kind: kind, flowKey: "welcome", statusCode: status)
    }

    /// Every kind gets its own sentence.
    ///
    /// Written as a table over an explicit list rather than a loop over a
    /// `CaseIterable`: `Kind` is deliberately not `CaseIterable` (it is a
    /// public enum whose cases map to HTTP, not a menu), so a new case has to
    /// be added here by hand. The uniqueness assertion below is what makes
    /// forgetting expensive.
    func testEachKindHasItsOwnHeadline() {
        let cases: [(FlowFetchError.Kind, String)] = [
            (.notFound, "This flow is not published"),
            (.unauthorized, "The API key was rejected"),
            (.forbidden, "This API key can't open that flow"),
            (.network, "Couldn't reach the server"),
            (.invalidPayload, "The flow couldn't be read"),
            (.server, "The server had a problem"),
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(view(fetchError(kind)).headline, expected)
        }
        let headlines = Set(cases.map { view(fetchError($0.0)).headline })
        XCTAssertEqual(
            headlines.count, cases.count,
            "two kinds share a headline — the screen can no longer tell them apart")
    }

    /// 401 and 404 are the two an integrator actually hits, and confusing them
    /// costs an afternoon: one is the key, the other is the flow.
    func testUnauthorizedAndNotFoundAreNotConfusable() {
        XCTAssertNotEqual(
            view(fetchError(.unauthorized, status: 401)).headline,
            view(fetchError(.notFound, status: 404)).headline)
    }

    /// Anything that is not a fetch failure still gets a sentence rather than
    /// an empty line — the original bug's shape, if not its cause.
    func testNonFetchErrorFallsBackToAGenericHeadline() {
        struct Odd: Error {}
        XCTAssertEqual(view(Odd()).headline, "Something went wrong")
        XCTAssertFalse(view(Odd()).detail.isEmpty)
    }

    /// Debug builds carry the actionable text. Tests are a debug build, so
    /// this is the branch under test; the release branch is asserted by its
    /// absence — see the type's doc comment for why it says less.
    func testDebugDetailNamesTheFlowAndTheFix() {
        let detail = view(fetchError(.notFound)).detail
        XCTAssertTrue(
            detail.contains("welcome"),
            "the detail should name the key that failed, got: \(detail)")
        XCTAssertTrue(detail.contains("404"), "the detail should carry the status")
    }

    func testHeadlineAndDetailAreNeverEmpty() {
        let kinds: [FlowFetchError.Kind] = [
            .notFound, .unauthorized, .forbidden, .network, .invalidPayload, .server,
        ]
        for kind in kinds {
            let v = view(fetchError(kind))
            XCTAssertFalse(v.headline.isEmpty, "\(kind) has no headline")
            XCTAssertFalse(v.detail.isEmpty, "\(kind) has no detail")
        }
    }
}
