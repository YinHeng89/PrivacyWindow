// swift-tools-version: 6.0
import PackageDescription

// The app's logic lives in `PrivacyCore` rather than in the executable target
// so that `PrivacyCoreTests` can import it: SwiftPM does not let a test target
// depend on an executable, and the executable's `@main` would collide with the
// test runner's own entry point anyway.
let package = Package(
    name: "PrivacyWindow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PrivacyCore",
            path: "Sources/PrivacyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PrivacyWindow",
            dependencies: ["PrivacyCore"],
            path: "Sources/PrivacyWindow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PrivacyCoreTests",
            dependencies: ["PrivacyCore"],
            path: "Tests/PrivacyCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
