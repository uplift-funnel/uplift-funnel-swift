import XCTest

@testable import UpliftLayout

/// The `video` node, which was in the schema, in the editor's Add menu and in
/// the inspector — and decoded to nothing.
///
/// Two separate failures produced one symptom. The decoder never read a
/// video's props, so the node carried no source; and the sizing switch had no
/// case for it, so a `video` with no explicit height was a HUG box with no
/// measurable content and solved to zero tall. An author could add one,
/// publish it, and find an empty gap on the device with nothing anywhere
/// saying why.
final class VideoLeafTests: XCTestCase {
    /// A fixed-metric measurer, so a frame assertion is about the video's own
    /// sizing rather than about anybody's font.
    private struct Ruler: TextMeasuring {
        func measure(_ run: TextRunSpec) -> TextMetrics {
            TextMetrics(lines: [TextLine(text: run.text, width: 10)], width: 10, height: 20)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { 10 }
    }

    private func node(_ props: [String: Any], box: [String: Any] = [:]) -> LayoutNode {
        let tree = LayoutDecoder.layoutTree(
            screen: ["root": ["type": "box", "children": [
                ["type": "video", "props": props, "self": box],
            ]]],
            input: LayoutInput(now: 0, screenEnteredAt: 0)
        )
        return tree!.children[0]
    }

    func testCarriesTheSource() {
        let n = node(["url": "https://cdn.example.com/clip.mp4"])
        XCTAssertEqual(n.video?.url, "https://cdn.example.com/clip.mp4")
    }

    /// The half of the bug that survived even once a player existed: a box
    /// with no intrinsic content and no aspect resolves against zero.
    func testClaimsABoxInsteadOfSolvingToNothing() {
        let n = node(["url": "https://cdn.example.com/clip.mp4"])
        XCTAssertEqual(n.width, .fill, "a video with no stated width must claim the row")
        XCTAssertEqual(n.aspect, 1.5, "and a height to go with it")
    }

    /// The fallback must not fight an author who stated the box.
    ///
    /// Asserted on the solved frame rather than on `aspect`: the default
    /// aspect is still assigned here and is simply inert, because `aspect`
    /// derives whichever axis is not otherwise determined and both of these
    /// are. Asserting it were nil would be asserting an implementation detail
    /// that does not match how the solver reads the field.
    func testAnExplicitBoxIsLeftAlone() throws {
        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(
            screen: ["root": ["type": "box", "children": [
                [
                    "type": "video", "props": ["url": "https://x/c.mp4"],
                    "self": ["width": 200, "height": 120],
                ],
            ]]],
            input: LayoutInput(now: 0, screenEnteredAt: 0)
        ))
        XCTAssertEqual(tree.children[0].width, .points(200))

        let viewport = Viewport(size: Size2D(width: 390, height: 844), safeTop: 0)
        let solved = try FlexSolver(measurer: Ruler()).solve(root: tree, viewport: viewport)
        let frame = try XCTUnwrap(solved.first { $0.path == "0" }?.rect)
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.height, 120, "an explicit height wins over the fallback aspect")
    }

    /// Silence is the default, and it is a product decision rather than a
    /// technical one — a flow that makes noise unasked is the worst thing a
    /// phone can do on someone's commute.
    func testDefaultsAreQuietAndLooping() {
        let n = node(["url": "https://x/c.mp4"])
        XCTAssertEqual(n.video?.muted, true)
        XCTAssertEqual(n.video?.loop, true)
        XCTAssertEqual(n.video?.autoplay, true)
        XCTAssertEqual(n.video?.controls, false, "a decorative loop with a scrubber looks broken")
    }

    func testTheAuthorCanOverrideEveryFlag() {
        let n = node([
            "url": "https://x/c.mp4",
            "muted": false, "loop": false, "autoplay": false, "controls": true,
        ])
        XCTAssertEqual(n.video?.muted, false)
        XCTAssertEqual(n.video?.loop, false)
        XCTAssertEqual(n.video?.autoplay, false)
        XCTAssertEqual(n.video?.controls, true)
    }

    /// The poster rides the ordinary image path, which is what lets a still
    /// paint with no player present — before the first frame decodes, on a
    /// network that never delivers, and in the paint goldens.
    func testPosterPaintsThroughTheImagePath() {
        let n = node([
            "url": "https://x/c.mp4",
            "poster": "https://cdn.example.com/still.jpg",
        ])
        XCTAssertEqual(n.video?.poster, "https://cdn.example.com/still.jpg")
        XCTAssertEqual(n.image?.url, "https://cdn.example.com/still.jpg")
    }

    func testNoPosterMeansNoImage() {
        let n = node(["url": "https://x/c.mp4"])
        XCTAssertNil(n.video?.poster)
        XCTAssertNil(n.image, "an empty poster must not become an image node with no url")
    }

    /// The spec has to survive into the display list: the renderer finds a
    /// video by walking paint items, because it hangs a real player at the
    /// frame this pass solved rather than drawing one.
    func testTheSpecReachesTheDisplayList() throws {
        let tree = try XCTUnwrap(LayoutDecoder.layoutTree(
            screen: ["root": ["type": "box", "children": [
                ["type": "video", "props": ["url": "https://x/c.mp4"]],
            ]]],
            input: LayoutInput(now: 0, screenEnteredAt: 0)
        ))
        let viewport = Viewport(size: Size2D(width: 390, height: 844), safeTop: 0)
        let solved = try FlexSolver(measurer: Ruler()).solve(root: tree, viewport: viewport)
        let list = try DisplayListBuilder.build(root: tree, frames: solved, size: viewport.size)
        let withVideo = list.items.filter { $0.video != nil }
        XCTAssertEqual(withVideo.count, 1)
        XCTAssertEqual(withVideo.first?.video?.url, "https://x/c.mp4")
        XCTAssertGreaterThan(
            withVideo.first?.frame.height ?? 0, 0,
            "a video with a zero-height frame is the original bug"
        )
    }
}
