import SwiftUI

/// Stand-in for a real OS dialog / auth sheet / purchase sheet.
///
/// A handler `await`s `ask(_:)`, which suspends until the user taps a button —
/// so BOTH branches of a flow are walkable (deny a permission, cancel a
/// purchase) without wiring a real integration first. Mirrors the Flutter
/// example's `demoConfirm`.
@MainActor
final class DemoPrompt: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var message = ""
    @Published private(set) var confirmLabel = "Allow"
    /// Info-only prompts (the link handler) get a single OK button.
    @Published private(set) var isInfo = false

    /// What the flow asked the app to do, newest first.
    ///
    /// The demo's real output: walking a flow with this on screen is the
    /// fastest way to see which handoff a given screen actually triggers.
    @Published private(set) var log: [String] = []

    private var continuation: CheckedContinuation<Bool, Never>?

    /// Suspends until the user answers. A second ask while one is still open
    /// resolves the first as denied rather than dropping its continuation.
    func ask(_ message: String, confirmLabel: String = "Allow") async -> Bool {
        resolve(false)
        self.message = message
        self.confirmLabel = confirmLabel
        isInfo = false
        isPresented = true
        return await withCheckedContinuation { self.continuation = $0 }
    }

    /// Fire-and-forget notice — the analog of the Flutter demo's snackbar.
    func info(_ message: String) {
        resolve(false)
        self.message = message
        isInfo = true
        isPresented = true
    }

    /// Idempotent: resuming twice would trap, so the continuation is cleared
    /// as it resolves.
    func resolve(_ granted: Bool) {
        isPresented = false
        continuation?.resume(returning: granted)
        continuation = nil
    }

    func note(_ line: String) {
        log = Array(([line] + log).prefix(40))
    }

    func clearLog() { log = [] }
}
