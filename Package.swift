// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpliftFunnel",
    platforms: [
        .iOS(.v15),
        // macOS is included only so `swift build` / `swift test` run from the CLI;
        // UIKit-only code is gated behind `#if canImport(UIKit)`.
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "UpliftFunnel",
            targets: ["UpliftFunnel"]
        ),
    ],
    targets: [
        .target(
            name: "UpliftFunnel",
            path: "Sources/UpliftFunnel"
        ),
        .testTarget(
            name: "UpliftFunnelTests",
            dependencies: ["UpliftFunnel"],
            path: "Tests/UpliftFunnelTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
