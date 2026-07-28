import Foundation

// Scheme policy for `url:<href>` actions.
//
// A flow's `url:` actions (markdown links and `url:` buttons) are authored
// content: they arrive over the network as strings and end up at the host
// app's `LinkHandler`, which typically hands them straight to
// `UIApplication.shared.open`. Without a scheme check that turns "can author a
// flow" into "can make the host app open any URL on the device" — third-party
// app deep links, `file://`, and the host app's OWN deep links, which usually
// skip the auth the UI would have enforced.
//
// So the SDK only forwards schemes on an allow-list. Apps that deliberately
// drive their own deep links from a flow opt those schemes in explicitly via
// `UpliftFunnel.registerLinkHandler(_:allowedSchemes:)`.

extension UpliftFunnel {
    /// Schemes forwarded to the host's link opener without an explicit opt-in:
    /// the web plus the three "contact the business" schemes onboarding copy
    /// actually uses. Everything else — custom app schemes, `file`, `data`,
    /// `javascript` — is dropped unless the host allows it.
    public nonisolated static let defaultAllowedLinkSchemes: Set<String> = [
        "https", "http", "mailto", "tel", "sms",
    ]
}

/// Whether `url` may be handed to the host's link opener.
///
/// Requires an absolute URL with a scheme in `allowedSchemes`. Relative and
/// scheme-less hrefs are rejected: there is no base URL to resolve them
/// against, so what the OS would do with one is anyone's guess.
func isAllowedLinkURL(_ url: String, allowedSchemes: Set<String>) -> Bool {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let parsed = URL(string: trimmed),
          let scheme = parsed.scheme
    else { return false }
    return allowedSchemes.contains(scheme.lowercased())
}
