import Foundation

// Developer-facing diagnostics.
//
// The SDK already logged in a few places — `[funnel] events: …` from the
// uploader, `[funnel] background revalidation failed …` from the fetcher —
// each written at the call site with its own `#if DEBUG print(…)`. The one
// path that never logged was the one that matters most: a foreground
// `start()` that throws leaves the host with a blank error view and nothing
// in the console to say why. This is that call, in one place, so the next
// failure path added does not have to reinvent the prefix.
//
// ── DEBUG only, deliberately ────────────────────────────────────────────────
//
// A library that prints into a customer's release console is noise they did
// not ask for and cannot switch off. Release builds compile the body away
// entirely, and the `@autoclosure` means the message is never even built —
// a caller can interpolate freely without paying for it in a shipped app.
//
// A host that wants failures in production has the supported route: pass
// `errorView:` to `UpliftFunnelFlowView` (or call `UpliftFunnel.start`
// directly) and report the error however that app already reports errors.
//
// ── Never log the API key ───────────────────────────────────────────────────
//
// It travels in a header, so it is not in any URL logged here, and nothing in
// this file should ever be given one. The flow key, the HTTP status and the
// request URL are all safe and are what a developer needs to tell 401 from
// 404 without a proxy.
enum UpliftLog {
    /// Something failed and the developer needs to know.
    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[funnel] \(message())")
        #endif
    }
}
