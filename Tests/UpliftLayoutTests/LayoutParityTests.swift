import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

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

        // Grouped by node, because a text node with SPANS is recorded as one
        // run per span — `"€8.99"` and `" / week"` arrive separately at the
        // same path, since each is its own inline box. They sit side by side on
        // one line, so the node's width is their sum and its height is one
        // line, not two. Indexing only by the individual span texts would leave
        // the joined string the decoder produces unmeasurable.
        var byPath: [String: [(text: String, lines: [Double], perLine: Double)]] = [:]

        for case let r as [String: Any] in (doc["runs"] as? [Any] ?? []) {
            guard let text = r["text"] as? String,
                  let lines = r["lines"] as? [NSNumber],
                  let path = r["path"] as? String else { continue }
            let size = (r["fontSize"] as? NSNumber)?.doubleValue ?? 16
            // `lineHeight` arrives as a CSS string: "22.4px" or "normal".
            let lhRaw = (r["lineHeight"] as? String) ?? ""
            let perLine = Double(lhRaw.replacingOccurrences(of: "px", with: "")) ?? size * 1.2
            let widths = lines.map(\.doubleValue)
            // Quantised PER LINE, then summed — which is what Chromium does,
            // and the difference is visible: a 43.2pt line height over two
            // lines is 86.375 (lu(43.2) × 2), not lu(86.4) = 86.390625. One
            // sixty-fourth, and it moves every sibling below it.
            runs[text] = (widths, size, lu(perLine) * Double(widths.count))
            byPath[path, default: []].append((text, widths, perLine))
        }

        for (_, parts) in byPath where parts.count > 1 {
            // Only when every part is a single line; a wrapped span set would
            // need real inline layout, and nothing in the corpus has one.
            guard parts.allSatisfy({ $0.lines.count == 1 }) else { continue }
            let joined = parts.map(\.text).joined()
            let width = parts.reduce(0.0) { $0 + ($1.lines.first ?? 0) }
            let height = lu(parts.map(\.perLine).max() ?? 0)
            runs[joined] = ([width], parts[0].lines.first ?? 0, height)
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
        // The store data the golden route renders with. It is not in the
        // document — a price comes from StoreKit — so the two sides have to
        // agree on it explicitly or they are laying out different text.
        let products = [
            "ai_interior_weekly": ["price": "€8.99", "period": "week"],
            "ai_interior_monthly": ["price": "€22.99", "period": "month"],
        ]
        return LayoutInput(selections: selections, variables: variables, products: products)
    }

    // MARK: - the comparison

    private func compare(
        shot: String,
        measurer override: (any TextMeasuring)? = nil,
        tolerance: Double = 0
    ) throws -> (matched: Int, failures: [String], worst: Double) {
        let base = try json("\(shot).frames")
        let params = try XCTUnwrap(base["params"] as? [String: Any])
        let expected = try XCTUnwrap(base["frames"] as? [[String: Any]])

        let fixture = try json(fixtureName(params["fixture"] as? String ?? "slice"))
        let index = (params["screen"] as? NSNumber)?.intValue ?? 0
        let tree = try XCTUnwrap(
            LayoutDecoder.layoutTree(
                flow: fixture,
                screenIndex: index,
                locale: params["locale"] as? String,
                input: input(from: params)
            ),
            "\(shot): the decoder produced no tree"
        )

        // The box the document was laid out INTO, recorded by the oracle
        // rather than guessed. It is not a constant, which is what the guess of
        // 743 got wrong: a screen whose `top_bar` shows a back chevron gets a
        // 24pt chrome bar, so the body is 719 there — and the pinned footer,
        // which resolves against exactly this box, sat 24pt low on every screen
        // that has one.
        let recorded = try XCTUnwrap(base["viewport"] as? [String: Any], "\(shot): no viewport")
        // The SAFE TOP comes from the recording too, for the same reason the
        // viewport does. It is not the status bar alone: it is the status bar
        // PLUS the chrome row, which is 44pt when the top bar carries an
        // affordance and 20pt when it only reserves the strip — 95 and 71.
        // Hardcoding 51 put every node under a bleeding hero 20pt out, a
        // whole-screen shift that reads as a solver fault and is really the two
        // runs laying out different screens.
        let viewport = Viewport(
            size: Size2D(
                width: (recorded["width"] as? NSNumber)?.doubleValue ?? 390,
                height: (recorded["height"] as? NSNumber)?.doubleValue ?? 743
            ),
            safeTop: (base["safeTop"] as? NSNumber)?.doubleValue ?? 51
        )

        let solved = try FlexSolver(measurer: override ?? (try measurer(for: shot)))
            .solve(root: tree, viewport: viewport)
        let byPath = Dictionary(uniqueKeysWithValues: solved.map { ($0.path, $0.rect) })

        var failures: [String] = []
        var matched = 0
        var worstOff = 0.0
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
            let off = max(abs(got.x - e.x), abs(got.y - e.y),
                          abs(got.width - e.w), abs(got.height - e.h))
            if off > worstOff { worstOff = off }
            if off <= tolerance {
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
        return (matched, failures, worstOff)
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
            "web-01-paywall-default": 27,   // of 39
            "web-02-paywall-monthly": 27,   // of 39
            "web-03-welcome": 7,            // of 8
            "web-04-name-input": 8,         // of 9
            "web-05-focus-unanswered": 19,  // of 20
            "web-06-focus-answered": 22,    // of 23
            "web-07-name-invalid": 8,       // of 9
        ]
        var report: [String] = []
        for (shot, want) in floor.sorted(by: { $0.key < $1.key }) {
            let (matched, failures, _) = try compare(shot: shot)
            let total = matched + failures.count
            report.append("  \(shot): \(matched)/\(total)")
            if !failures.isEmpty {
                for f in failures { report.append("      \(f)") }
            }
            XCTAssertGreaterThanOrEqual(
                matched, want,
                "\(shot) matched \(matched)/\(total), below its recorded floor of \(want)"
            )
        }
        print("FRAME PARITY\n" + report.joined(separator: "\n"))
    }

    /// The same comparison with CoreText doing the shaping, which is what runs
    /// on a device.
    ///
    /// This began far worse than the stub run, and the shape of the failure was
    /// the whole finding: the worst offsets were exactly `lu(16 × 1.45)` and
    /// `lu(20 × 1.5)` — ONE LINE — which looked like the two shapers disagreeing
    /// about where to break. They do not. Measured at the width Chromium
    /// actually used, CoreText breaks all 74 runs in the corpus onto the same
    /// number of lines (`WrapBoundaryTests`). The lines were wrong because the
    /// WIDTH was wrong, and each wrap was correct for the width it was handed.
    ///
    /// Four causes, all now fixed, none of them the breaking algorithm:
    ///   - intrinsic sizes floored to the layout grid, so a hug box came out
    ///     narrower than the content that sized it and the content reflowed
    ///     inside it (`luCeil`)
    ///   - a row's hug height measured its children at the row's whole width
    ///     instead of at their share after flexing
    ///   - `hug` meant max-content for a box and fit-content for text, so a row
    ///     asked for 373pt in the 342 it was going to get and was measured there
    ///   - icons decoded through the type ramp, giving them 1.45 line heights
    ///     where the renderer pins 1
    ///
    /// The stub could not see any of it. It replays fixed line counts per
    /// string, so its text cannot re-wrap however wrong the width is — which is
    /// exactly why both measurers are kept. It is now the LESS accurate of the
    /// two on the paywall, because its joined-span entry is built from ink
    /// rects where the browser sizes from advances.
    ///
    /// The paywall then closed on two more, and the second is the interesting
    /// one. Spans became real inline segments rather than one joined string in
    /// the node's own typography — a price is 22pt bold beside 22pt regular
    /// under a node with no typography at all. That left 1.73pt on the €, which
    /// looked like a font difference and was not: the dashboard's body carries
    /// Geist's `font-feature-settings: "cv11", "ss01"`, feature settings are
    /// inherited, and the phone frame never reset them — so the BROWSER was
    /// applying Geist's stylistic sets to the system font and the preview
    /// disagreed with the device. CoreText was right; the baseline was wrong.
    func testFrameParityWithCoreTextShaping() throws {
        // What each shot's REMAINING failures are, so the floors below mean
        // something. Raise them as these close; never lower one.
        // Every remaining failure is now ONE THING: the emoji point. The worst
        // offset across all seven shots is 1.000, which is Apple Color Emoji's
        // advance quantisation — a bitmap face whose advance is already a whole
        // number, so there is no finer value to round the browser's way. Three
        // shots are exact; the two focus screens carry it on three icons each
        // and it cascades to their siblings.
        let floor: [String: Int] = [
            "web-01-paywall-default": 33,   // of 39
            "web-02-paywall-monthly": 33,   // of 39
            "web-03-welcome": 8,            // of 8 — exact
            "web-04-name-input": 9,         // of 9 — exact
            "web-05-focus-unanswered": 8,   // of 20
            "web-06-focus-answered": 9,     // of 23
            "web-07-name-invalid": 9,       // of 9 — exact
        ]
        var report: [String] = []
        for (shot, want) in floor.sorted(by: { $0.key < $1.key }) {
            // Within a quarter point, which is four times the layout grid and
            // still finer than a device pixel at 3×.
            let real = try compare(shot: shot, measurer: CoreTextMeasurer(), tolerance: 0.25)
            let total = real.matched + real.failures.count
            report.append(String(
                format: "  %@: %d/%d within 0.25pt, worst %.3f",
                shot, real.matched, total, real.worst
            ))
            for f in real.failures.prefix(8) { report.append("      \(f)") }
            XCTAssertGreaterThanOrEqual(
                real.matched, want,
                "\(shot) matched \(real.matched)/\(total) with real shaping, "
                + "below its recorded floor of \(want)"
            )
        }
        print("CORETEXT PARITY\n" + report.joined(separator: "\n"))
    }
}
