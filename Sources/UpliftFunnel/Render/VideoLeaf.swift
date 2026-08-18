import AVFoundation
import SwiftUI

import UpliftLayout

#if canImport(UIKit)
import UIKit
#endif

// A real player, hung at the frame the layout pass solved.
//
// ── Why this is not painted like everything else ────────────────────────────
//
// The renderer draws a screen by walking a display list into a CGContext:
// boxes, gradients, text, images. A video cannot be drawn that way — there is
// nothing to draw until frames are decoding, and decoding them by hand to blit
// into a canvas would be a video player written badly. So a `video` leaf takes
// the route the native controls take: the canvas leaves its box alone, and a
// real view is positioned over the frame the solver produced.
//
// This is why `video` was invisible rather than broken. The node decoded to
// nothing, took part in no layout, and painted no pixels — an author could add
// one, publish it, and find an empty gap on the device with nothing anywhere
// saying why.
//
// ── The poster is not a nicety ──────────────────────────────────────────────
//
// `Decode` copies a video's poster onto the node's `image`, so the still paints
// through the ordinary image path underneath this view. That covers the moment
// before the first frame decodes, a network that never delivers, and the paint
// goldens — which run in a CGContext with no player at all and would otherwise
// have to special-case video or record a grey rectangle as correct.

/// Owns one `AVPlayer` for the lifetime of a video leaf.
///
/// A class, held in `@State`, because an `AVPlayer` must not be rebuilt on
/// every `body`: re-creating it restarts playback from zero, and a screen with
/// a countdown re-evaluates its body every second.
@MainActor
final class VideoLeafPlayer {
    let player: AVPlayer
    private var loopObserver: NSObjectProtocol?

    init(spec: VideoSpec) {
        player = AVPlayer(url: URL(string: spec.url) ?? URL(fileURLWithPath: "/dev/null"))
        // Muted by default and by schema default. An onboarding flow that
        // makes noise on its own is the single most complained-about thing a
        // phone can do, and the author has to ask for it explicitly.
        player.isMuted = spec.muted
        // Never let a flow's video duck the user's music or stop their podcast.
        // `AVPlayer` claims the session otherwise, and a muted decorative clip
        // silencing Spotify is a bug report about the host app, not about us.
        player.actionAtItemEnd = spec.loop ? .none : .pause

        if spec.loop {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}

#if canImport(UIKit)

/// A `UIView` whose backing layer IS the player layer.
///
/// `layerClass` rather than adding a sublayer: a sublayer has to be resized by
/// hand on every bounds change, and the one that gets missed is the rotation
/// nobody tested.
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        // Matches an image node's default `fit: cover`, so a video and a still
        // in the same slot frame their subject the same way.
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

#endif

/// One video leaf.
struct VideoLeaf: View {
    let spec: VideoSpec
    let corners: Corners

    @State private var owner: VideoLeafPlayer?

    var body: some View {
        surface
            // The poster is painted by the canvas underneath, so this view
            // stays transparent until there are frames to show.
            .onAppear {
                let owned = owner ?? VideoLeafPlayer(spec: spec)
                owner = owned
                if spec.autoplay { owned.player.play() }
            }
            .onDisappear {
                // Paused rather than torn down. A screen the user scrolls back
                // to should not restart, and a flow that advances tears the
                // whole view down anyway.
                owner?.player.pause()
            }
    }

    @ViewBuilder
    private var surface: some View {
        #if canImport(UIKit)
        if let owner {
            Group {
                if spec.controls {
                    // AVKit's own controls. Only when the author asked: a
                    // decorative loop with a scrubber over it looks broken.
                    AVKitPlayer(player: owner.player)
                } else {
                    PlayerSurface(player: owner.player)
                }
            }
            .clipShape(RoundedCorners(corners: corners))
            .allowsHitTesting(spec.controls)
        } else {
            Color.clear
        }
        #else
        // macOS is here so `swift build` and `swift test` run from the CLI.
        // Nothing renders a flow there.
        Color.clear
        #endif
    }
}

#if canImport(UIKit)
import AVKit

/// AVKit's player view, without its default padding/background.
struct AVKitPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif

/// The node's own corner radii, as a clip shape.
///
/// A video sitting in a 14pt-cornered card has to be cut by it. The canvas
/// clips its own drawing; this view is not the canvas's drawing.
struct RoundedCorners: Shape {
    let corners: Corners

    func path(in rect: CGRect) -> Path {
        let fitted = corners.fitted(in: Size2D(width: rect.width, height: rect.height))
        var path = Path()
        let tl = CGFloat(fitted.topLeft), tr = CGFloat(fitted.topRight)
        let br = CGFloat(fitted.bottomRight), bl = CGFloat(fitted.bottomLeft)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
