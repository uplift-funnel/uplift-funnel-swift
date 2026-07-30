import XCTest
@testable import UpliftLayout

/// The solver against the browser, on the real documents.
///
/// The unit tests assert rules; this asserts the whole answer. Every node's
/// frame is compared with what Chromium produced for the same document, node by
/// node, so a failure names the path rather than showing a picture.
///
/// The measurer is the reason this can be exact rather than approximate. Text
/// is shaped from CHROMIUM'S OWN recorded metrics, so any difference here is
/// the solver's arithmetic and nothing else. A CoreText run comes later and is
/// asserted separately; keeping them apart is what makes a failure say which of
/// the two is wrong, instead of leaving both suspects.
final class LayoutParityTests: XCTestCase {
    // MARK: - the oracle's text metrics, replayed

    struct StubMeasurer: TextMeasuring {
        /// text → the lines Chromium broke it into, and how wide each came out.
        let runs: [String: (lines: [Double], size: Double, height: Double)]

        func measure(_ run: TextRunSpec) -> TextMetrics {
            guard let rec = runs[run.text] else {
                // A run the baseline never saw means the tree being laid out is
                // not the tree that was dumped — a decode bug, not a metric
                // gap. Zero would hide it inside a plausible frame.
                return TextMetrics(lines: [], width: .nan, height: .nan)
            }
            return TextMetrics(
                lines: rec.lines.map { TextLine(text: run.text, width: $0) },
                width: rec.lines.max() ?? 0,
                height: rec.height
            )
        }

        func minContentWidth(_ run: TextRunSpec) -> Double {
            runs[run.text]?.lines.max() ?? 0
        }
    }

    // MARK: - loading

    private func baselineURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Baseline"),
            "missing baseline \(name).json — run Scripts/sync-baseline.sh"
        )
    }

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: try baselineURL(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `catalog` and `slice` are what the web shot list calls the two fixtures.
    private func fixtureName(_ key: String) -> String {
        key == "catalog" ? "interior-paywall" : "wellness-onboarding"
    }

    private func measurer(for shot: String) throws -> StubMeasurer {
        let doc = try json("\(shot).text")
        var runs: [String: (lines: [Double], size: Double, height: Double)] = [:]
        for case let r as [String: Any] in (doc["runs"] as? [Any] ?? []) {
            guard let text = r["text"] as? String,
                  let lines = r["lines"] as? [NSNumber] else { continue }
            let size = (r["fontSize"] as? NSNumber)?.doubleValue ?? 16
            // `lineHeight` arrives as a CSS string: "22.4px" or "normal".
            let lhRaw = (r["lineHeight"] as? String) ?? ""
            let perLine = Double(lhRaw.replacingOccurrences(of: "px", with: "")) ?? size * 1.2
            // Quantised PER LINE, then summed — which is what Chromium does,
            // and the difference is visible: a 43.2pt line height over two
            // lines is 86.375 (lu(43.2) × 2), not lu(86.4) = 86.390625. One
            // sixty-fourth, and it moves every sibling below it.
            runs[text] = (lines.map(\.doubleValue), size, lu(perLine) * Double(lines.count))
        }
        return StubMeasurer(runs: runs)
    }

    /// The answers the shot was dumped with — read from the baseline itself, so
    /// the two can never be laid out against different selections.
    private func input(from params: [String: Any]) -> LayoutInput {
        var selections: [String: String] = [:]
        var variables: [String: String] = [:]
        for pair in ((params["sel"] as? String) ?? "").split(separator: ",") {
            let bits = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = bits.first else { continue }
            let v = bits.count > 1 ? String(bits[1]) : ""
            selections[String(k)] = v
            variables[String(k)] = v
        }
        return LayoutInput(selections: selections, variables: variables)
    }

    // MARK: - the comparison

    private func compare(shot: String) throws -> (matched: Int, failures: [String]) {
        let base = try json("\(shot).frames")
        let params = try XCTUnwrap(base["params"] as? [String: Any])
        let expected = try XCTUnwrap(base["frames"] as? [[String: Any]])

        let fixture = try json(fixtureName(params["fixture"] as? String ?? "slice"))
        let index = (params["screen"] as? NSNumber)?.intValue ?? 0
        let tree = try XCTUnwrap(
            Decoder.layoutTree(
                flow: fixture,
                screenIndex: index,
                locale: params["locale"] as? String,
                input: input(from: params)
            ),
            "\(shot): the decoder produced no tree"
        )

        // The body the web measured into. Width comes from the recorded root;
        // HEIGHT is the device's, not the root's — a `position: fixed` footer
        // pins to the screen, and a root that hugs its content is shorter than
        // the screen it sits on. Using the root's height put the footer 485pt
        // too high.
        let rootFrame = try XCTUnwrap(expected.first { ($0["path"] as? String) == "" })
        let viewport = Viewport(
            size: Size2D(
                width: (rootFrame["w"] as? NSNumber)?.doubleValue ?? 390,
                height: 743
            ),
            safeTop: 51
        )

        let solved = try FlexSolver(measurer: try measurer(for: shot))
            .solve(root: tree, viewport: viewport)
        let byPath = Dictionary(uniqueKeysWithValues: solved.map { ($0.path, $0.rect) })

        var failures: [String] = []
        var matched = 0
        for want in expected {
            guard let path = want["path"] as? String else { continue }
            guard let got = byPath[path] else {
                failures.append("\(path): missing — the solver never produced this node")
                continue
            }
            let e = (
                x: (want["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (want["y"] as? NSNumber)?.doubleValue ?? 0,
                w: (want["w"] as? NSNumber)?.doubleValue ?? 0,
                h: (want["h"] as? NSNumber)?.doubleValue ?? 0
            )
            if got.x == e.x && got.y == e.y && got.width == e.w && got.height == e.h {
                matched += 1
            } else {
                // Only the axes that actually differ, so the eye goes to the
                // cause rather than to four numbers of which two agree.
                var bits: [String] = []
                if got.x != e.x { bits.append(String(format: "x %.4f≠%.4f", got.x, e.x)) }
                if got.y != e.y { bits.append(String(format: "y %.4f≠%.4f", got.y, e.y)) }
                if got.width != e.w { bits.append(String(format: "w %.4f≠%.4f", got.width, e.w)) }
                if got.height != e.h { bits.append(String(format: "h %.4f≠%.4f", got.height, e.h)) }
                failures.append("\(path): " + bits.joined(separator: "  "))
            }
        }
        return (matched, failures)
    }

    // MARK: - the report

    /// Reported as one number per shot rather than as pass/fail per node.
    ///
    /// The solver is new and does not match yet; failing loudly on the first
    /// divergence would hide how far off it is, and "which nodes are wrong" is
    /// the only question worth answering while it is being built. The assertion
    /// is a RATCHET: it fails if the match rate drops, so progress is locked in
    /// as it is made and the number in `floor` only ever goes up.
    func testFrameParityAgainstTheWebBaseline() throws {
        // Raise these as the solver improves. Never lower one to make a run
        // green — that is the whole point of writing them down.
        let floor: [String: Int] = [
            "web-01-paywall-default": 25,   // of 39
            "web-02-paywall-monthly": 25,   // of 39
            "web-03-welcome": 7,            // of 8
            "web-04-name-input": 4,         // of 9
            "web-05-focus-unanswered": 19,  // of 20
            "web-06-focus-answered": 22,    // of 23
            "web-07-name-invalid": 4,       // of 9
        ]
        var report: [String] = []
        for (shot, want) in floor.sorted(by: { $0.key < $1.key }) {
            let (matched, failures) = try compare(shot: shot)
            let total = matched + failures.count
            report.append("  \(shot): \(matched)/\(total)")
            if !failures.isEmpty {
                for f in failures.prefix(6) { report.append("      \(f)") }
                if failures.count > 6 { report.append("      … \(failures.count - 6) more") }
            }
            XCTAssertGreaterThanOrEqual(
                matched, want,
                "\(shot) matched \(matched)/\(total), below its recorded floor of \(want)"
            )
        }
        print("FRAME PARITY\n" + report.joined(separator: "\n"))
    }
}
