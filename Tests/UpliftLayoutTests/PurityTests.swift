import XCTest
@testable import UpliftLayout

/// The layout engine's boundary, enforced.
///
/// `UpliftLayout` declares no dependencies, and it is tempting to assume that
/// stops it importing SwiftUI. It does not: SwiftPM happily resolves system
/// frameworks from a target with an empty `dependencies` list, so `import
/// SwiftUI` in here compiles today and the whole premise — layout is a pure
/// function, portable to Dart and Kotlin, testable without a view hierarchy —
/// quietly stops being true.
///
/// So the boundary is a test. It reads the sources rather than the binary,
/// because the point is to fail on the line that was written, in the review
/// where it was written.
final class PurityTests: XCTestCase {
    /// Frameworks that would tie layout to one platform's rendering stack.
    private static let forbidden = [
        "SwiftUI", "UIKit", "AppKit", "CoreText", "CoreGraphics",
        "QuartzCore", "Combine", "WebKit",
    ]

    private func sourceFiles() throws -> [URL] {
        // #filePath is Tests/UpliftLayoutTests/PurityTests.swift; the sources
        // are two levels up and across.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UpliftLayout")
        let found = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(found.isEmpty, "no sources found at \(root.path) — the test is looking in the wrong place")
        return found
    }

    func testLayoutImportsNoFramework() throws {
        for url in try sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = String(trimmed.dropFirst("import ".count))
                    .split(separator: " ").first.map(String.init) ?? ""
                XCTAssertFalse(
                    Self.forbidden.contains(module),
                    """
                    \(url.lastPathComponent) imports \(module).
                    UpliftLayout must stay a pure function of (nodes, viewport, text metrics).
                    If you need text shaped, ask through TextMeasuring; if you need to draw, \
                    that belongs in UpliftFunnel.
                    """
                )
            }
        }
    }

    /// Foundation is allowed — it is portable and carries no rendering — but it
    /// is worth knowing when it arrives, because most uses of it in a layout
    /// engine are a `CGFloat` in disguise.
    func testForeignGeometryTypesAreNotUsed() throws {
        for url in try sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            for name in ["CGFloat", "CGRect", "CGSize", "CGPoint", "NSAttributedString"] {
                XCTAssertFalse(
                    source.contains(name),
                    "\(url.lastPathComponent) uses \(name); UpliftLayout has its own geometry."
                )
            }
        }
    }
}
