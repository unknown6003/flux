// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [
        // Keep Sonoma (14) as the minimum and test the current macOS release in CI.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Flux",
            path: "Sources/Flux",
            swiftSettings: [
                // Swift 5 language mode keeps the AppKit/SwiftUI bridge free of
                // strict-concurrency friction while we still annotate the
                // main-actor surfaces explicitly. Pragmatic for a menu-bar agent.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
