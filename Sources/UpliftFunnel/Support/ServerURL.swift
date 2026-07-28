import Foundation

// Validation for the `serverUrl` override passed to `UpliftFunnel.configure`,
// and safe composition of the API URLs built on top of it.

/// Why a `serverUrl` was rejected. Surfaced through `configure`'s precondition
/// message; kept typed so the tests can assert on the reason.
enum ServerURLError: Error, CustomStringConvertible {
    case notAbsoluteHTTP(String)
    case cleartextInRelease(String)

    var description: String {
        switch self {
        case .notAbsoluteHTTP(let raw):
            return "serverUrl '\(raw)' must be an absolute http(s) URL, "
                + "e.g. https://api.upliftfunnel.com"
        case .cleartextInRelease(let raw):
            return "serverUrl '\(raw)' is cleartext http:// — that's debug-only. "
                + "Ship an https:// URL."
        }
    }
}

/// Validates and normalizes a `serverUrl` override.
///
/// Cleartext `http://` stays available in debug builds so a simulator can talk
/// to a dev box — `allowCleartext` carries `#if DEBUG` from the call site. A
/// release build that shipped it would put the API key, the subject id and
/// every event (which carry whatever the funnel asked the user) on the wire in
/// the clear, and would let anyone on the network serve the flow JSON the SDK
/// renders and acts on.
func normalizeServerUrl(_ raw: String, allowCleartext: Bool) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          scheme == "https" || scheme == "http"
    else { throw ServerURLError.notAbsoluteHTTP(raw) }

    if scheme == "http" && !allowCleartext {
        throw ServerURLError.cleartextInRelease(raw)
    }

    // A trailing slash composes into `https://host//v1/flows/x`, which gateways
    // often answer with a redirect the SDK deliberately refuses to follow.
    var normalized = trimmed
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized
}

/// Percent-encodes `key` for use as a single path segment.
///
/// Without this a key carrying `/`, `?` or `#` would rewrite the request path
/// or graft a query onto it. `.` and `..` are refused outright — as whole
/// segments they're the one thing percent-encoding leaves meaningful to a
/// server's path normalizer.
func encodeFlowKey(_ key: String) -> String? {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
}

/// Builds `<serverUrl>/<path>/<key>` with `key` encoded as one path segment.
/// Returns nil only for a key `encodeFlowKey` refuses — `serverUrl` was already
/// validated at `configure` time.
func apiURL(serverUrl: String, path: String, key: String) -> URL? {
    guard let encoded = encodeFlowKey(key) else { return nil }
    return URL(string: "\(serverUrl)/\(path)/\(encoded)")
}
