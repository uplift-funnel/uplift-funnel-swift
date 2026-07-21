import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

// AsyncImage replacement with real caching: an in-memory NSCache plus a
// shared URLCache-backed session honoring HTTP cache headers. AsyncImage on
// iOS 15 has no persistence and refetches across screen revisits — funnels
// revisit images constantly (back nav, carousel), so this matters.

final class RemoteImageLoader: ObservableObject {
    static let memoryCache = NSCache<NSURL, PlatformImage>()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            diskPath: "uplift-funnel-images")
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    @Published var image: PlatformImage?
    @Published var failed = false

    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard let url else {
            failed = true
            return
        }
        if let cached = Self.memoryCache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                let (data, _) = try await Self.session.data(from: url)
                guard let decoded = PlatformImage(data: data) else {
                    await MainActor.run { self?.failed = true }
                    return
                }
                Self.memoryCache.setObject(decoded, forKey: url as NSURL)
                await MainActor.run { self?.image = decoded }
            } catch {
                await MainActor.run { self?.failed = true }
            }
        }
    }

    deinit { task?.cancel() }
}

/// Network image with the SDK's neutral gradient placeholder while loading
/// and on error, so layout stays stable.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                #endif
            } else {
                imagePlaceholderGradient
            }
        }
        .onAppear { loader.load(url) }
    }
}

/// Neutral placeholder gradient (matches the Flutter `_imagePlaceholder`).
var imagePlaceholderGradient: some View {
    LinearGradient(
        colors: [Color(.sRGB, red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2F / 255.0),
                 Color(.sRGB, red: 0x4A / 255.0, green: 0x4A / 255.0, blue: 0x55 / 255.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}
