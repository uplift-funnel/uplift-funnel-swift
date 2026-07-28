import Foundation

/// Refuses HTTP redirects on every task in the session it's attached to.
///
/// `URLSession` follows redirects by default and re-sends the original headers
/// to the new location — including `Authorization` and `X-Uplift-Subject-Id`.
/// A 3xx from a misconfigured or hostile server would therefore hand the API
/// key and the subject id to an arbitrary host. The Uplift API never redirects,
/// so returning nil here stops the chain and lets the 3xx fall through to the
/// caller's non-2xx error path.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
