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
        ),
        .testTarget(
            name: "FluxUITests",
            dependencies: ["FluxUI", "FluxCore"],
            path: "Tests/FluxUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FluxPlatform",
            dependencies: ["FluxCore"],
            path: "Sources/FluxPlatform",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxUIProbe",
            dependencies: ["FluxCore", "FluxUI"],
            path: "Scripts/rebuild/UIProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxMenuCaptureProbe",
            path: "Scripts/rebuild/MenuCaptureProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxVisibilityProbe",
            dependencies: ["FluxCore", "FluxPlatform"],
            path: "Scripts/rebuild/VisibilityProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluxPlatformTests",
            dependencies: ["FluxCore", "FluxPlatform"],
            path: "Tests/FluxPlatformTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FluxApplication",
            dependencies: ["FluxCore", "FluxPlatform", "FluxUI"],
            path: "Sources/FluxApplication",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxNativeCandidate",
            dependencies: ["FluxApplication", "FluxCore", "FluxPlatform", "FluxUI"],
            path: "Scripts/rebuild/NativeCandidate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluxApplicationTests",
            dependencies: ["FluxApplication", "FluxCore", "FluxUI"],
            path: "Tests/FluxApplicationTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxRatingProbe",
            dependencies: ["FluxApplication", "FluxCore", "FluxUI"],
            path: "Scripts/rebuild/RatingProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FluxMenuBarLayoutProbe",
            path: "Scripts/rebuild/MenuBarLayoutProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
