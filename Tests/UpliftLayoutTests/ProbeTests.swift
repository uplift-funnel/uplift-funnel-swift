import XCTest
@testable import UpliftLayout
@testable import UpliftFunnel

/// Temporary probe: solve every screen of the flows named in `PROBE_FLOWS`
/// (comma-separated absolute paths) and print which ones throw. The twin of
/// `packages/layout/tests/probe.test.ts`, so a screen that solves on one
/// platform and not the other names itself.
final class ProbeTests: XCTestCase {
    struct Ruler: TextMeasuring {
        func measure(_ run: TextRunSpec) -> TextMetrics {
            TextMetrics(lines: [TextLine(text: run.text, width: 10)], width: 10, height: 20)
        }
        func minContentWidth(_ run: TextRunSpec) -> Double { 10 }
    }

    func testProbe() throws {
        let paths = (ProcessInfo.processInfo.environment["PROBE_FLOWS"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        try XCTSkipIf(paths.isEmpty, "set PROBE_FLOWS")

        for path in paths {
            print("--- \((path as NSString).lastPathComponent)")
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let flow = (doc["flow"] as? [String: Any]) ?? doc
            let screens = try XCTUnwrap(flow["screens"] as? [[String: Any]])
            for (i, s) in screens.enumerated() {
                let id = s["id"] as? String ?? "\(i)"
                // The whole device path, not just the solver: `displayList`
                // also paints, and the renderer's `try?` swallows whichever of
                // the two threw.
                do {
                    _ = try ScreenRenderer(measurer: Ruler()).displayList(
                        flow: flow, screenIndex: i,
                        viewport: Viewport(size: Size2D(width: 402, height: 874), safeTop: 59)
                    )
                    print("  ok       \(id)")
                } catch {
                    print("  FAIL     \(id): \(error)")
                }
            }
        }
    }
}
