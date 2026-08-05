import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif

// Turning what a photo picker returned into bytes, and deciding whether those
// bytes are worth sending.
//
// ── Why this is not trivial ─────────────────────────────────────────────────
//
// `photo_upload` stores whatever the host's picker handed back — "a file path,
// an uploaded asset id, a URL" — and `PhotoUpload.swift` says in as many words
// that the SDK never interprets it. Inference needs bytes, so something has to
// give. What gives is the smallest possible piece: the SDK will *try* to read
// the reference as a local file, and asks the host for anything else.
//
// The alternative — requiring every customer to register a resolver — makes the
// common case (a picker returning a file URL) cost an integration step for no
// reason, and a customer who forgets gets a flow that silently falls back.

/// Resolves a `photo_upload` reference the SDK cannot read on its own.
///
/// Register one when the picker hands back something private to the app: an
/// asset id in its own store, a PHAsset identifier, a key in a cache. Return
/// nil for "I do not know this either", which lands the flow on its fallback.
public typealias InferenceMediaResolver = @Sendable (String) async -> Data?

/// Bytes plus the media type the server needs to accept them.
struct ResolvedMedia: Sendable {
    let data: Data
    let contentType: String
}

enum InferenceMedia {
    /// What the SDK will read without asking anyone.
    ///
    /// A `file://` URL and a bare absolute path are what every picker on this
    /// platform produces; a `data:` URI is what a host that already has the
    /// bytes in memory is most likely to hand back. An `https://` URL is
    /// deliberately absent: fetching one would make the SDK a downloader of
    /// arbitrary hosts on a path that then uploads what it got, and the host is
    /// far better placed to decide whether its own URL is safe to read.
    static func resolveLocally(_ reference: String) -> ResolvedMedia? {
        if reference.hasPrefix("data:") {
            return decodeDataUri(reference)
        }
        let url: URL?
        if reference.hasPrefix("file://") {
            url = URL(string: reference)
        } else if reference.hasPrefix("/") {
            url = URL(fileURLWithPath: reference)
        } else {
            url = nil
        }
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return ResolvedMedia(data: data, contentType: contentType(forPath: url.pathExtension))
    }

    private static func decodeDataUri(_ uri: String) -> ResolvedMedia? {
        guard let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mediaType = String(header.dropLast(";base64".count))
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return ResolvedMedia(
            data: data,
            contentType: mediaType.isEmpty ? "image/jpeg" : mediaType)
    }

    /// Extension → media type, over the set the server accepts.
    ///
    /// Guessing wrong here is a 415 from the server, so the fallback is jpeg —
    /// what a camera roll is full of — rather than octet-stream, which the
    /// server refuses outright.
    static func contentType(forPath ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "image/jpeg"
        }
    }
}

// MARK: - the pre-filter

/// Why a photo was not worth sending, in words a screen can show.
public struct InferencePreflightFailure: Sendable, Equatable {
    /// Stable, for branching: "unreadable" | "too_small" | "too_dark" | "no_face".
    public let code: String
    /// One sentence, addressed to the person holding the phone.
    public let message: String
}

/// What the SDK checks before a photo leaves the device.
///
/// Spec 04's engineering control 2, and spec 15 criterion 9: a photo that fails
/// here produces **no network call at all**. That cuts both the volume and the
/// App Store 5.1.2(i) surface, since on-device processing is exempt from the
/// disclosure.
///
/// ── Why face detection is off by default ────────────────────────────────────
///
/// The spec says "face presence / quality". Face presence is right for a selfie
/// flow and wrong for every other legitimate `image_analysis` — a meal photo for
/// calorie estimation, a skin patch, a room. Nothing in the schema says "expect
/// a face here", so making it unconditional would break those flows for a
/// benefit only selfie flows get. The universally-safe checks run always; the
/// face check is a switch the host throws when its flow is about faces.
public struct InferencePreflight: Sendable {
    /// Reject an image whose shorter side is under this. Below it there is
    /// nothing for a model to read, and the answer is noise wearing confidence.
    public var minimumDimension: Int = 200

    /// Downscale anything whose longer side exceeds this before upload.
    ///
    /// The device half of the server's `TOO_LARGE` class: a 12-megapixel selfie
    /// is several megabytes of detail no attribute model uses, and shrinking it
    /// here is the difference between a two-second wait and a twelve-second one
    /// on a phone network.
    public var maximumDimension: Int = 1536

    /// JPEG quality for the downscale. 0.8 is where the size curve flattens.
    public var compressionQuality: Double = 0.8

    /// Hard ceiling, matching the server's. Something past this after a
    /// downscale is not a photo.
    public var maximumBytes: Int = 8 * 1024 * 1024

    /// Require a detectable face. Off by default — see the type's note.
    public var requiresFace: Bool = false

    public init() {}
}

enum InferencePreflightResult: Sendable {
    case pass(ResolvedMedia)
    case reject(InferencePreflightFailure)
}

extension InferencePreflight {
    /// Run the checks, downscaling on the way through.
    ///
    /// Audio is passed through: the checks below are all about pixels, and a
    /// clip that fails a made-up audio heuristic would be a flow that refuses
    /// to run for a reason nobody can act on.
    func apply(_ media: ResolvedMedia) -> InferencePreflightResult {
        guard media.contentType.hasPrefix("image/") else {
            return media.data.count > maximumBytes
                ? .reject(InferencePreflightFailure(
                    code: "too_large",
                    message: "That file is too large to analyse."))
                : .pass(media)
        }

        #if canImport(UIKit)
        guard let image = UIImage(data: media.data) else {
            return .reject(InferencePreflightFailure(
                code: "unreadable",
                message: "That image could not be read. Try taking it again."))
        }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        if min(width, height) < minimumDimension {
            return .reject(InferencePreflightFailure(
                code: "too_small",
                message: "That photo is too small to analyse. Try a closer, sharper one."))
        }
        if requiresFace, !FaceDetector.containsFace(image) {
            return .reject(InferencePreflightFailure(
                code: "no_face",
                message: "We couldn't find a face. Try better light, facing the camera."))
        }

        let prepared = downscaled(image) ?? media
        if prepared.data.count > maximumBytes {
            return .reject(InferencePreflightFailure(
                code: "too_large",
                message: "That photo is too large to analyse. Try a smaller one."))
        }
        return .pass(prepared)
        #else
        // No UIKit — the package builds for tests on other platforms, and a
        // byte ceiling is the one check that does not need an image decoder.
        return media.data.count > maximumBytes
            ? .reject(InferencePreflightFailure(
                code: "too_large",
                message: "That photo is too large to analyse. Try a smaller one."))
            : .pass(media)
        #endif
    }

    #if canImport(UIKit)
    /// Re-encode at or under `maximumDimension`. Returns nil when the original
    /// is already small enough, so an untouched photo is uploaded untouched.
    private func downscaled(_ image: UIImage) -> ResolvedMedia? {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > CGFloat(maximumDimension) else { return nil }
        let ratio = CGFloat(maximumDimension) / longest
        let target = CGSize(
            width: (image.size.width * image.scale * ratio).rounded(),
            height: (image.size.height * image.scale * ratio).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: CGFloat(compressionQuality)) else {
            return nil
        }
        return ResolvedMedia(data: data, contentType: "image/jpeg")
    }
    #endif
}

// MARK: - face detection

/// Vision, behind a wall so the rest of the file builds without it.
///
/// `VNDetectFaceRectanglesRequest` rather than landmarks: presence is the whole
/// question, landmarks cost more, and — the part that matters — a rectangle is
/// discarded the moment it is counted. Nothing here produces a face template,
/// which is the one control that keeps this outside GDPR Art. 9 (spec 04).
enum FaceDetector {
    #if canImport(UIKit)
    static func containsFace(_ image: UIImage) -> Bool {
        #if canImport(Vision)
        guard let cgImage = image.cgImage else { return false }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A detector that failed to run has not said "no face". Refusing
            // here would block a perfectly good photo because Vision was busy.
            return true
        }
        return !(request.results ?? []).isEmpty
        #else
        return true
        #endif
    }
    #endif
}
