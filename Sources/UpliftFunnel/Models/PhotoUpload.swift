import Foundation

// Photo-picker handoff contract for the `photo_upload` primitive, ported
// from the Flutter SDK's `photo_upload.dart`. The SDK deliberately ships no
// camera or gallery dependency — apps that collect photos already have a
// picker and already own the OS permission prompts that come with it.

/// What the authored node allows, handed to the host's picker.
public struct PhotoUploadRequest: Sendable {
    /// "camera" | "library" | "both" — the sources the author permitted.
    public let source: String

    /// "square" | "circle" — the crop the screen is drawn for.
    public let shape: String

    public init(source: String, shape: String) {
        self.source = source
        self.shape = shape
    }
}

/// Returns a reference the host can resolve later — a file path, an
/// uploaded asset id, a URL — or nil when the user cancels. The value is
/// stored in the node's `bind.save_to` variable verbatim; the SDK never
/// interprets it.
public typealias PhotoUploadHandler = @MainActor (PhotoUploadRequest) async -> String?
