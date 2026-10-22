// swift-tools-version:6.0
// LimitBar — a macOS menu bar app with the usage limits of your AI coding CLIs.
// Build the app: scripts/build-app.sh <out-dir>
import PackageDescription

let package = Package(
    name: "LimitBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LimitBar",
            path: "Sources/LimitBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LimitBarTests", dependencies: ["LimitBar"], path: "tests/LimitBarTests")
    ]
)
