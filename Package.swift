// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TeleNotch",
    platforms: [.macOS(.v26)],
    targets: [
        // Sparkle 2.10.0 (auto-updates), vendored by scripts/fetch-sparkle.sh (checksum-pinned).
        .binaryTarget(name: "Sparkle", path: "vendor/Sparkle.xcframework"),
        .executableTarget(
            name: "TeleNotch",
            dependencies: ["Sparkle"],
            path: "Sources/TeleNotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
