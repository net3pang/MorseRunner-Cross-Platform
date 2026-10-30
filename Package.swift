// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MorseRunner",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // The engine, DSP, contests — pure Foundation, no platform frameworks.
        // Builds and runs on macOS, Linux, and Windows.
        .target(
            name: "MorseRunnerCore",
            path: "Sources/MorseRunnerCore"
        ),
        // The macOS native application (AppKit + AVAudioEngine).
        .executableTarget(
            name: "MorseRunner",
            dependencies: ["MorseRunnerCore"],
            path: "Sources/MorseRunnerMac",
            resources: [
                .copy("../../Resources")
            ]
        ),
        // Cross-platform terminal UI (macOS / Linux / Windows).
        .executableTarget(
            name: "MorseRunnerTUI",
            dependencies: ["MorseRunnerCore"],
            path: "Sources/MorseRunnerTUI",
            resources: [
                .copy("../../Resources")
            ]
        ),
        // Headless engine verification (swift test).
        .testTarget(
            name: "MorseRunnerCoreTests",
            dependencies: ["MorseRunnerCore"],
            path: "Sources/EngineTest"
        ),
        .testTarget(
            name: "MorseRunnerMacTests",
            dependencies: [.target(name: "MorseRunner", condition: .when(platforms: [.macOS]))],
            path: "Sources/MacTest"
        )
    ]
)
