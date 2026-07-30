import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// Which runs sit near a wrap boundary, and by how much.
///
/// The CoreText parity run fails by whole lines rather than by fractions — the
/// worst offsets are `lu(16 × 1.45)` and `lu(20 × 1.5)` exactly. That is not
/// drift: a sub-point width difference is harmless in the middle of a box and
/// decisive at the point where the last word either fits or does not. So the
/// question is not "how far apart are the two shapers" — that is answered, and
/// the median is a hundredth of a point — but "how many runs are close enough
/// to the edge for a hundredth to matter, and what is the actual slack".
///
/// The measurement here is that slack, per run, at the box width the browser
/// really used: the distance between the last word that fit and the box's
/// edge. A run with three points of slack is safe under any shaper; one with
/// three hundredths is a coin toss.
final class WrapBoundaryTests: XCTestCase {
    private let measurer = CoreTextMeasurer()

    private struct Run {
        let shot: String
        let path: String
        let text: String
        let size: Double
        let weight: Int
        let letterSpacing: Double
        let lineHeight: Double?
        let chromiumLines: Int
        /// Chromium's own width for each line it broke the run onto.
        let chromiumWidths: [Double]
        /// The run on one unbroken line, which is what sizes a hugging element.
        let maxContent: Double
        /// The element's own width, from the frames baseline — the real box.
        let box: Double
    }

    private static let shots = [
        "web-01-paywall-default", "web-02-paywall-monthly", "web-03-welcome",
        "web-04-name-input", "web-05-focus-unanswered", "web-06-focus-answered",
        "web-07-name-invalid",
    ]

    private func load(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline")
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
    }

    /// Every text run, paired with the box its element actually occupied.
    private func runs() throws -> [Run] {
        var out: [Run] = []
        for shot in Self.shots {
            let frames = try load("\(shot).frames")
            var boxes: [String: Double] = [:]
            for f in (frames["frames"] as? [[String: Any]]) ?? [] {
                if let p = f["path"] as? String, let w = (f["w"] as? NSNumber)?.doubleValue {
                    boxes[p] = w
                }
            }
            let text = try load("\(shot).text")
            for r in (text["runs"] as? [[String: Any]]) ?? [] {
                guard let t = r["text"] as? String,
                      let path = r["path"] as? String,
                      let lines = r["lines"] as? [NSNumber],
                      let box = boxes[path] else { continue }
                let size = (r["fontSize"] as? NSNumber)?.doubleValue ?? 16
                let px = Double(((r["lineHeight"] as? String) ?? "").replacingOccurrences(of: "px", with: ""))
                let ls = Double(((r["letterSpacing"] as? String) ?? "").replacingOccurrences(of: "px", with: "")) ?? 0
                out.append(Run(
                    shot: shot, path: path, text: t, size: size,
                    weight: Int((r["fontWeight"] as? String) ?? "400") ?? 400,
                    letterSpacing: ls,
                    lineHeight: px.map { $0 / size },
                    chromiumLines: lines.count,
                    chromiumWidths: lines.map(\.doubleValue),
                    maxContent: (r["maxContent"] as? NSNumber)?.doubleValue ?? 0,
                    box: box
                ))
            }
        }
        return out
    }

    private func spec(_ r: Run, maxWidth: Double?) -> TextRunSpec {
        TextRunSpec(
            text: r.text, fontSize: r.size, fontWeight: r.weight,
            letterSpacing: r.letterSpacing, lineHeight: r.lineHeight, maxWidth: maxWidth
        )
    }

    /// How much room was left on the tightest line — the margin by which the
    /// next word did NOT fit. Small means one shaper's rounding decides it.
    private func slack(_ r: Run) -> Double {
        let laid = measurer.measure(spec(r, maxWidth: r.box))
        guard !laid.lines.isEmpty else { return .infinity }
        // The line that came closest to filling the box.
        let fullest = laid.lines.map(\.width).max() ?? 0
        return r.box - fullest
    }

    // MARK: - the census

    func testReportWrapSlackAcrossTheCorpus() throws {
        let all = try runs()
        XCTAssertGreaterThan(all.count, 30, "the corpus should offer more runs than this")

        var rows: [(slack: Double, disagrees: Bool, label: String)] = []
        for r in all {
            let laid = measurer.measure(spec(r, maxWidth: r.box))
            let disagrees = laid.lines.count != r.chromiumLines
            rows.append((
                slack(r),
                disagrees,
                String(
                    format: "%@ %@ @%.0f/%d box %.2f  chromium %d lines, coretext %d",
                    r.shot.replacingOccurrences(of: "web-0", with: "").prefix(2).description,
                    r.text.prefix(28).description, r.size, r.weight, r.box,
                    r.chromiumLines, laid.lines.count
                )
            ))
        }

        let disagreeing = rows.filter(\.disagrees)
        let tight = rows.filter { $0.slack < 1.0 && !$0.slack.isInfinite }
        print("""
        WRAP BOUNDARY CENSUS
          \(all.count) runs measured at the box their element really occupied
          \(disagreeing.count) disagree with Chromium about the line count
          \(tight.count) sit within 1pt of the edge
        """)
        for row in rows.sorted(by: { $0.slack < $1.slack }).prefix(10) {
            print(String(format: "   slack %7.3f  %@%@", row.slack, row.disagrees ? "✗ " : "  ", row.label))
        }

        // THE FINDING. Given the width Chromium actually used, CoreText breaks
        // every run in the corpus onto the same number of lines — the shapers
        // do agree about breaking. So the whole-line errors in the CoreText
        // parity run are not caused by the wrap decision at all: they are
        // caused by the text arriving at a DIFFERENT WIDTH, and the wrap that
        // follows is correct for the width it was handed.
        //
        // Which moves the question one level up, to what sizes the box.
        XCTAssertTrue(
            disagreeing.isEmpty,
            "at Chromium's own width, these broke differently: \(disagreeing.map(\.label))"
        )
    }

    /// Where the width actually goes wrong: hugging elements, not wrapping ones.
    ///
    /// This is how the emoji tracking was found. The slack census showed emoji
    /// runs at MINUS three points — the glyph was wider than the box Chromium
    /// had sized for it — on elements whose entire width IS one glyph. Three
    /// points is plenty: the emoji sits in a row beside a label, the label's
    /// share shrinks by three, and a subtitle that fit on two lines in Chromium
    /// takes three here. The whole-line error arrived from a font's tracking,
    /// not from the breaking algorithm.
    ///
    /// It is now at most a point, and that point is irreducible — see
    /// `CoreTextMeasurerTests.testEmojiResolveToTheUntrackedFace`. The bound is
    /// asserted rather than the direction, because both remaining outliers (the
    /// emoji and the €) are font-table facts and neither should quietly grow.
    func testEmojiAreTheWidthErrorNotTheBreaker() throws {
        var emoji: [(Double, String)] = []
        var plain: [(Double, String)] = []
        for r in try runs() where r.chromiumLines == 1 {
            // Against Chromium's MAX-CONTENT, not its line rect: a line rect
            // ends at the last glyph's ink where max-content carries its full
            // advance, and the gap is real — 0.43pt on the paywall's ✕. Not
            // against the box either, since a text element set to fill is far
            // wider than its text.
            let got = measurer.maxContentWidth(spec(r, maxWidth: nil))
            let delta = abs(got - r.maxContent)
            let label = "\(r.text.prefix(24)) @\(r.size)/\(r.weight)"
            if r.text.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                emoji.append((delta, label))
            } else {
                plain.append((delta, label))
            }
        }
        let emojiWorst = emoji.max { $0.0 < $1.0 }
        let plainWorst = plain.max { $0.0 < $1.0 }
        print(String(
            format: "WIDTH ERROR BY KIND\n   emoji  worst %.3fpt  %@\n   plain  worst %.3fpt  %@  (over %d runs)",
            emojiWorst?.0 ?? 0, emojiWorst?.1 ?? "—",
            plainWorst?.0 ?? 0, plainWorst?.1 ?? "—", plain.count
        ))

        // Emoji are the only outlier left, and it is a font-table fact rather
        // than slack to spend: Apple Color Emoji quantises its advance to a
        // whole number, so where Chromium reads `size/2 + 12` this reads
        // `size/2 + 13` and there is no finer value in between. Every non-emoji
        // run is inside a third of a point.
        XCTAssertLessThanOrEqual(
            emojiWorst?.0 ?? 0, 1.0,
            "an emoji drifted past the quantisation bound: \(emojiWorst?.1 ?? "")"
        )
        XCTAssertLessThan(
            plainWorst?.0 ?? 0, 0.3,
            "a non-emoji run drifted: \(plainWorst?.1 ?? "")"
        )
    }
}
