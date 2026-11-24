// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TeleNotch",
    platforms: [.macOS(.v26)],
    dependencies: [
        // On-device speaker diarization (tells the "Others" voices apart). Apache-2.0.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        // Sparkle 2.10.0 (auto-updates), vendored by scripts/fetch-sparkle.sh (checksum-pinned).
        .binaryTarget(name: "Sparkle", path: "vendor/Sparkle.xcframework"),
        .executableTarget(
            name: "TeleNotch",
            dependencies: ["Sparkle", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/TeleNotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
