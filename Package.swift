// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [
        // Sonoma (14) is the floor so Flux covers the latest three releases —
        // Sonoma 14, Sequoia 15, Tahoe 26 — and stays forward-compatible with
        // the upcoming Golden Gate (27).
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
