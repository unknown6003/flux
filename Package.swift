// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [
        // Keep Sonoma (14) as the minimum and test the current macOS release in CI.
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "FluxCore",
            path: "Sources/FluxCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluxCoreTests",
            dependencies: ["FluxCore"],
            path: "Tests/FluxCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Flux",
            path: "Sources/Flux",
            swiftSettings: [
                // Swift 5 language mode keeps the AppKit/SwiftUI bridge free of
                // strict-concurrency friction while we still annotate the
                // main-actor surfaces explicitly. Pragmatic for a menu-bar agent.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "FluxTelemetryProbe",
            dependencies: ["FluxCore"],
            path: "Scripts/rebuild/TelemetryProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FluxUI",
            dependencies: ["FluxCore"],
            path: "Sources/FluxUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
