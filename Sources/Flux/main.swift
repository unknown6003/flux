import AppKit

// Flux runs as a menu-bar agent: no Dock icon, no main window, no app menu.
// We drive NSApplication manually instead of using the SwiftUI `@main`/Settings
// scene so we have full control over status-item geometry and window lifetime.
// SwiftUI is still used for the Settings UI, hosted inside an AppKit window.
//
// `main.swift`'s top-level code is nonisolated, but the process entry point is
// already the main thread — so we assert main-actor isolation to satisfy the
// concurrency checker. `run()` blocks here, keeping `delegate` (held weakly by
// NSApplication) alive for the whole process lifetime.
MainActor.assumeIsolated {
    // Offscreen render mode for deterministic UI capture (dev/testing only).
    //   Flux --render-settings <path> [light|dark]
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--render-settings"), idx + 1 < args.count {
        let appearance = idx + 2 < args.count ? args[idx + 2] : "light"
        SettingsRenderer.render(to: args[idx + 1], appearanceName: appearance)
        exit(0)
    }
    if let idx = args.firstIndex(of: "--snapshot"), idx + 1 < args.count {
        let dark = idx + 2 < args.count && args[idx + 2] == "dark"
        SettingsSnapshot.capture(to: args[idx + 1], dark: dark)
        exit(0)
    }
    if args.contains("--selftest") {
        SelfTest.run()
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // .accessory == LSUIElement behaviour: present in the menu bar, absent from
    // the Dock and Cmd-Tab. The Info.plist also sets LSUIElement so this holds
    // even before the delegate runs.
    app.setActivationPolicy(.accessory)

    app.run()
}
