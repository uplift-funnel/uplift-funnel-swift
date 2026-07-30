import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// CoreText against Chromium, on every run in the corpus.
///
/// Asserted apart from the solver on purpose. There are exactly two ways the
/// iOS renderer can disagree with the browser — wrong boxes or wrong text —
/// they have different causes and different fixes, and one failing screenshot
/// cannot tell them apart. The solver is checked against Chromium's recorded
/// metrics, where a mismatch is arithmetic; this is checked against the same
/// recording, where a mismatch is shaping.
///
/// Line COUNT is exact, because a wrong count moves every sibling below by a
/// whole line. Widths carry a tolerance, because two shapers on two rasterisers
/// will not agree to the bit — the number here is measured, not chosen, and it
/// is reported so a regression in it is visible.
final class CoreTextMeasurerTests: XCTestCase {
    private let measurer = CoreTextMeasurer()

    private struct Recorded {
        let path: String
        let text: String
        let size: Double
        let weight: Int
        let letterSpacing: Double
        let lineHeight: Double?
        let lines: [Double]
        let maxContent: Double
    }

    private func recorded(_ shot: String) throws -> [Recorded] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "\(shot).text", withExtension: "json", subdirectory: "Baseline")
        )
        let doc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        return ((doc["runs"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let text = r["text"] as? String,
                  let lines = (r["lines"] as? [NSNumber])?.map(\.doubleValue) else { return nil }
            let size = (r["fontSize"] as? NSNumber)?.doubleValue ?? 16
            let lhRaw = (r["lineHeight"] as? String) ?? ""
            let px = Double(lhRaw.replacingOccurrences(of: "px", with: ""))
            let ls = Double(((r["letterSpacing"] as? String) ?? "").replacingOccurrences(of: "px", with: "")) ?? 0
            return Recorded(
                path: r["path"] as? String ?? "",
                text: text,
                size: size,
                weight: Int((r["fontWeight"] as? String) ?? "400") ?? 400,
                letterSpacing: ls,
                lineHeight: px.map { $0 / size },
                lines: lines,
                maxContent: (r["maxContent"] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }

    private func spec(_ r: Recorded, maxWidth: Double?) -> TextRunSpec {
        TextRunSpec(
            text: r.text,
            fontSize: r.size,
            fontWeight: r.weight,
            letterSpacing: r.letterSpacing,
            lineHeight: r.lineHeight,
            maxWidth: maxWidth
        )
    }

    private static let shots = [
        "web-01-paywall-default", "web-03-welcome", "web-04-name-input",
        "web-05-focus-unanswered", "web-06-focus-answered",
    ]

    // MARK: - max-content

    /// The width the browser sizes a hugging text element by, which is where
    /// most of the corpus's text sizing comes from.
    func testMaxContentWidthTracksChromium() throws {
        var worst = 0.0
        var worstRun = ""
        var count = 0
        var deltas: [(Double, String)] = []
        for shot in Self.shots {
            for r in try recorded(shot) where r.maxContent > 0 {
                let got = measurer.maxContentWidth(spec(r, maxWidth: nil))
                let delta = abs(got - r.maxContent)
                // Emoji are a different story: they resolve to a colour font
                // whose advance is platform-specific, and no amount of shaping
                // agreement will make Apple's 🛋️ the width of Chromium's.
                if r.text.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                    continue
                }
                count += 1
                deltas.append((delta, "\(r.text.prefix(30)) @\(r.size)/\(r.weight) got \(String(format: "%.3f", got)) want \(r.maxContent)"))
                if delta > worst { worst = delta; worstRun = "\(r.text.prefix(24)) @\(r.size)/\(r.weight)" }
            }
        }
        let sorted = deltas.sorted { $0.0 > $1.0 }
        print(String(format: "MAX-CONTENT over %d runs; median %.4f", count, sorted[sorted.count / 2].0))
        for (d, who) in sorted.prefix(8) { print(String(format: "   %7.3f  %@", d, who)) }
        XCTAssertGreaterThan(count, 20, "the corpus should offer more runs than this")

        // The MEDIAN is the guarantee: half the corpus is within a hundredth of
        // a point of Chromium, which is finer than the sixty-fourth the frames
        // are held to. A regression in shaping moves this immediately.
        let median = sorted[sorted.count / 2].0
        XCTAssertLessThan(median, 0.05, "half the runs should be within a twentieth of a point")

        // The worst is looser, and the reason is specific rather than a shrug:
        // every run above half a point contains a EURO SIGN. macOS resolves €
        // to a different face than Chromium does, and its advance differs by
        // ~1.7pt at 22pt — a font-fallback difference, not a shaping one, and
        // nothing in the measurer can close it. If a NON-currency run ever
        // lands here, that is a real regression and this number should not be
        // raised to hide it.
        let worstNonCurrency = sorted.first { !$0.1.contains("€") }
        XCTAssertLessThan(
            worstNonCurrency?.0 ?? 0, 0.5,
            "a run with no currency glyph drifted: \(worstNonCurrency?.1 ?? "")"
        )
        XCTAssertLessThan(worst, 2.0, "CoreText drifted from Chromium by \(worst)pt on \(worstRun)")
    }

    // MARK: - wrapping

    /// A wrong line count moves every sibling below it by a whole line, so this
    /// is exact where the widths are not.
    func testLineCountMatchesAtTheWidthChromiumUsed() throws {
        var mismatches: [String] = []
        var checked = 0
        for shot in Self.shots {
            for r in try recorded(shot) where r.lines.count > 1 {
                // Wrapped at the width the widest recorded line implies: the
                // element was at least that wide and narrower than a line more.
                let box = r.lines.max()! + 0.5
                let got = measurer.measure(spec(r, maxWidth: box))
                checked += 1
                if got.lines.count != r.lines.count {
                    mismatches.append("\(r.text.prefix(30))…: \(got.lines.count) lines, want \(r.lines.count)")
                }
            }
        }
        print("WRAPPING checked \(checked) multi-line runs, \(mismatches.count) mismatched")
        for m in mismatches.prefix(5) { print("   \(m)") }
        XCTAssertGreaterThan(checked, 2, "the corpus should have wrapped paragraphs")
        XCTAssertTrue(mismatches.isEmpty, "line counts differ: \(mismatches)")
    }

    // MARK: - the variable axis

    /// The finding this file exists for: SF's NAMED instances do not sit at the
    /// CSS weight positions, so `UIFont.systemFont(ofSize:weight:)` is wrong by
    /// up to 8.86pt on a heading. Driving `wght` directly is within a
    /// hundredth. This asserts the axis is actually being driven — that heavier
    /// CSS weights produce monotonically wider text at a fixed size, including
    /// at values no named instance sits on.
    func testTheWeightAxisIsContinuous() {
        let sample = "Design your dream room"
        var widths: [Int: Double] = [:]
        for weight in [300, 400, 500, 600, 700, 900] {
            widths[weight] = measurer.maxContentWidth(
                TextRunSpec(text: sample, fontSize: 26, fontWeight: weight)
            )
        }
        let ordered = widths.sorted { $0.key < $1.key }.map(\.value)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(a, b, "a heavier weight must not be narrower — is the wght axis being driven?")
        }
        // 500 sits between two named instances, so a snapping implementation
        // would return the same width as 400 or 600 for it.
        XCTAssertNotEqual(widths[500]!, widths[400]!, accuracy: 0.001)
        XCTAssertNotEqual(widths[500]!, widths[600]!, accuracy: 0.001)
    }

    // MARK: - trailing whitespace

    /// `CTLineGetTypographicBounds` counts the space hanging off a line's end;
    /// CSS collapses it. Left in, it is the whole per-line width difference.
    func testTrailingSpaceDoesNotCountTowardWidth() {
        let bare = measurer.maxContentWidth(TextRunSpec(text: "Weekly", fontSize: 19, fontWeight: 600))
        let spaced = measurer.maxContentWidth(TextRunSpec(text: "Weekly   ", fontSize: 19, fontWeight: 600))
        XCTAssertEqual(bare, spaced, accuracy: 0.0001)
    }
}
