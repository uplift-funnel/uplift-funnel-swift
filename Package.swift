// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FunnelOnboarding",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FunnelOnboarding",
            targets: ["FunnelOnboarding"]
        ),
    ],
    targets: [
        .target(
            name: "FunnelOnboarding",
            path: "Sources/FunnelOnboarding"
        ),
        .testTarget(
            name: "FunnelOnboardingTests",
            dependencies: ["FunnelOnboarding"],
            path: "Tests/FunnelOnboardingTests"
        ),
    ]
)
