import XCTest
@testable import UpliftFunnel

final class VersionTests: XCTestCase {
    /// `kUpliftFunnelSdkVersion` is what every analytics event reports as
    /// `sdk_version`. A Swift package has no manifest version to pin it to —
    /// the git tag is the version — so it's pinned here to the version the
    /// README tells people to install. That's the pair that actually drifts,
    /// and it already did: the constant sat at 0.1.0 while the README said
    /// 0.5.0, so every event was mislabelled.
    func testSdkVersionMatchesReadmeInstallVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UpliftFunnelTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

        let pattern = try NSRegularExpression(pattern: #"from:\s*"([^"]+)""#)
        let match = try XCTUnwrap(
            pattern.firstMatch(in: readme, range: NSRange(readme.startIndex..., in: readme)),
            #"README.md has no `from: "…"` install version"#)
        let versionRange = try XCTUnwrap(Range(match.range(at: 1), in: readme))

        XCTAssertEqual(kUpliftFunnelSdkVersion, String(readme[versionRange]))
    }
}
