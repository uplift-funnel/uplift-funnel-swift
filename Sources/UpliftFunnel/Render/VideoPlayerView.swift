import Foundation
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

// Real video playback for `video` nodes and full-bleed screen backgrounds:
// AVQueuePlayer + AVPlayerLooper, muted loop, aspect-fill. Falls back to the
// placeholder until the first frame is ready (and permanently on platforms
// without a player).

#if canImport(UIKit) && canImport(AVFoundation)

/// UIKit host whose backing layer IS an AVPlayerLayer, so video gravity and
/// resizing come for free.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    let contain: Bool

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = contain ? .resizeAspect : .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.videoGravity = contain ? .resizeAspect : .resizeAspectFill
    }
}

@MainActor
final class VideoNodeModel: ObservableObject {
    @Published var ready = false

    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?

    func configure(url: URL, autoplay: Bool, loop: Bool, muted: Bool) {
        guard looper == nil, statusObservation == nil else { return }
        let item = AVPlayerItem(url: url)
        player.isMuted = muted
        if loop {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.ready = true }
        }
        if autoplay {
            player.play()
        }
    }

    deinit {
        statusObservation?.invalidate()
    }
}

/// Inline video node with a real player. Falls back to `placeholder` until
/// the player is ready so cold paths stay on the deterministic poster.
struct VideoNodeView: View {
    let url: URL
    let autoplay: Bool
    let loop: Bool
    let muted: Bool
    let contain: Bool
    let height: Double
    let radius: Double
    let placeholder: AnyView

    @StateObject private var model = VideoNodeModel()

    var body: some View {
        ZStack {
            if model.ready {
                PlayerLayerRepresentable(player: model.player, contain: contain)
            } else {
                placeholder
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .onAppear {
            model.configure(url: url, autoplay: autoplay, loop: loop, muted: muted)
        }
        .onDisappear { model.player.pause() }
    }
}

/// Full-bleed muted-loop-autoplay background video layer. Transparent until
/// the first frame; poster/none while loading.
struct BackgroundVideoView: View {
    let url: URL

    @StateObject private var model = VideoNodeModel()

    var body: some View {
        ZStack {
            if model.ready {
                PlayerLayerRepresentable(player: model.player, contain: false)
            } else {
                Color.clear
            }
        }
        .onAppear {
            model.configure(url: url, autoplay: true, loop: true, muted: true)
        }
        .onDisappear { model.player.pause() }
    }
}

#else

/// macOS test-build fallback: always the placeholder.
struct VideoNodeView: View {
    let url: URL
    let autoplay: Bool
    let loop: Bool
    let muted: Bool
    let contain: Bool
    let height: Double
    let radius: Double
    let placeholder: AnyView

    var body: some View {
        placeholder
    }
}

struct BackgroundVideoView: View {
    let url: URL

    var body: some View { Color.clear }
}

#endif
