// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpliftFunnel",
    platforms: [
        // iOS 16 rather than 15. `ImageRenderer`, which the paint goldens need,
        // is 16+, and so is the `Layout` protocol the painter uses to place
        // children at solved rects. iOS 16 shipped in 2022; the layout engine
        // itself is in `UpliftLayout` and has no OS floor at all.
        .iOS(.v16),
        // macOS is included only so `swift build` / `swift test` run from the CLI;
        // UIKit-only code is gated behind `#if canImport(UIKit)`.
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "UpliftFunnel",
            targets: ["UpliftFunnel"]
        ),
    ],
    targets: [
        // The layout engine, deliberately dependency-free and framework-free.
        // It must not import SwiftUI, UIKit, AppKit or CoreText: layout is a
        // pure function from (node tree, viewport, text metrics) to frames, so
        // it can be unit-tested without a view hierarchy and ported verbatim to
        // Dart and Kotlin. `PurityTests` enforces the boundary, because SwiftPM
        // will not.
        .target(
            name: "UpliftLayout",
            path: "Sources/UpliftLayout"
        ),
        .target(
            name: "UpliftFunnel",
            dependencies: ["UpliftLayout"],
            path: "Sources/UpliftFunnel"
        ),
        .testTarget(
            name: "UpliftLayoutTests",
            dependencies: ["UpliftLayout"],
            path: "Tests/UpliftLayoutTests"
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
