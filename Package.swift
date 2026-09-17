// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrivacyWindow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PrivacyWindow",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
