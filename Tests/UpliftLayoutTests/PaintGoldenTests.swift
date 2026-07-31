import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// Pixels, on the same seven screens the frame baseline covers.
///
/// These goldens are OURS. They are deliberately not the web renderer's PNGs,
/// and the distinction matters enough to state: two rasterisers will never
/// agree on antialiasing, gamma or glyph hinting, so a cross-renderer image
/// diff can only ever be a threshold nobody can defend. What IS checked exactly
/// is checked elsewhere — the geometry against Chromium in `LayoutParityTests`,
/// the paint against the document in `DisplayListTests`. What these add is the
/// thing neither can see: that the draw calls happen, in the right order, with
/// nothing painted over or left out.
///
/// So: a regression detector, not a parity claim. Refresh with
/// `UPLIFT_REFRESH_GOLDENS=1 swift test --filter PaintGoldenTests` and READ the
/// diff — a golden that changed because the renderer improved and a golden that
/// changed because it broke look identical to git.
final class PaintGoldenTests: XCTestCase {
    /// The same shot list as the frame baseline, so the two never drift apart.
    private static let shots: [(name: String, fixture: String, screen: Int, sel: [String: String])] = [
        ("web-01-paywall-default", "interior-paywall", 0, [:]),
        ("web-02-paywall-monthly", "interior-paywall", 0, ["plan": "monthly"]),
        ("web-03-welcome", "wellness-onboarding", 0, [:]),
        ("web-04-name-input", "wellness-onboarding", 1, [:]),
        ("web-05-focus-unanswered", "wellness-onboarding", 2, [:]),
        ("web-06-focus-answered", "wellness-onboarding", 2, ["focus": "sleep", "first_name": "Alex"]),
        ("web-07-name-invalid", "wellness-onboarding", 1, ["first_name": ""]),
    ]

    /// 1×, not 3×. A golden's job here is to notice a missing or misplaced draw,
    /// which is just as visible at 390×743 and writes a file a hundredth the
    /// size into the repository.
    private static let scale = 1.0

    private var refreshing: Bool {
        ProcessInfo.processInfo.environment["UPLIFT_REFRESH_GOLDENS"] == "1"
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func render(_ shot: (name: String, fixture: String, screen: Int, sel: [String: String])) throws -> CGImage {
        let input = LayoutInput(
            selections: shot.sel,
            variables: shot.sel,
            products: [
                "ai_interior_weekly": ["price": "€8.99", "period": "week"],
                "ai_interior_monthly": ["price": "€22.99", "period": "month"],
            ]
        )
        return try XCTUnwrap(ScreenRenderer().render(
            flow: try fixture(shot.fixture),
            screenIndex: shot.screen,
            input: input,
            viewport: Viewport(size: Size2D(width: 390, height: 743), safeTop: 51),
            scale: Self.scale
        ), "\(shot.name) produced no image")
    }

    // MARK: - pixels

    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("no PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(url.lastPathComponent)")
    }

    /// Where the goldens live in the SOURCE tree, not the test bundle — a
    /// refresh has to update the files that get committed.
    private var goldenDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("PaintGoldens")
    }

    func testPaintGoldens() throws {
        var refreshed: [String] = []
        var failures: [String] = []

        for shot in Self.shots {
            let image = try render(shot)
            let file = goldenDir.appendingPathComponent("\(shot.name).png")

            guard !refreshing, FileManager.default.fileExists(atPath: file.path) else {
                try write(image, to: file)
                refreshed.append(shot.name)
                continue
            }

            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let want = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                failures.append("\(shot.name): the golden on disk is unreadable")
                continue
            }
            guard want.width == image.width, want.height == image.height else {
                failures.append(
                    "\(shot.name): \(image.width)×\(image.height) against a "
                    + "\(want.width)×\(want.height) golden"
                )
                continue
            }

            let a = pixels(want), b = pixels(image)
            var differing = 0
            var worst = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let d = max(
                    abs(Int(a[i]) - Int(b[i])),
                    abs(Int(a[i + 1]) - Int(b[i + 1])),
                    abs(Int(a[i + 2]) - Int(b[i + 2]))
                )
                // A channel or two apart is the rasteriser, not a change.
                if d > 4 { differing += 1 }
                worst = max(worst, d)
            }
            let ratio = Double(differing) / Double(a.count / 4)
            if ratio > 0.001 {
                // Written beside the golden so the two can be opened together.
                let actual = goldenDir.appendingPathComponent("\(shot.name).actual.png")
                try write(image, to: actual)
                failures.append(String(
                    format: "%@: %.3f%% of pixels differ (worst channel %d) — see %@",
                    shot.name, ratio * 100, worst, actual.lastPathComponent
                ))
            }
        }

        if !refreshed.isEmpty {
            print("PAINT GOLDENS written: \(refreshed.joined(separator: ", "))")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    // MARK: - what a blank golden would not catch

    /// A golden that is one flat colour has failed even if it matches itself.
    ///
    /// The first version of this renderer produced a perfectly stable, perfectly
    /// white 390×743 image on every shot, and a self-comparing golden was
    /// completely happy with it. This is the assertion that would have caught
    /// it: a real screen has many distinct colours and covers most of its area.
    func testARenderIsNotBlank() throws {
        for shot in Self.shots {
            let image = try render(shot)
            let px = pixels(image)
            var seen = Set<UInt32>()
            var nonWhite = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                let key = UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2])
                seen.insert(key)
                if key != 0xFF_FF_FF { nonWhite += 1 }
            }
            let coverage = Double(nonWhite) / Double(px.count / 4)
            XCTAssertGreaterThan(seen.count, 50, "\(shot.name) has \(seen.count) distinct colours")
            XCTAssertGreaterThan(
                coverage, 0.05,
                String(format: "%@ marks only %.1f%% of the screen", shot.name, coverage * 100)
            )
        }
    }
}
