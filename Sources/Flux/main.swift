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
        let tab = (idx + 3 < args.count ? SettingsTab(rawValue: args[idx + 3]) : nil) ?? .general
        SettingsRenderer.render(to: args[idx + 1], appearanceName: appearance, tab: tab)
        exit(0)
    }
    if let idx = args.firstIndex(of: "--snapshot"), idx + 1 < args.count {
        let dark = args[(idx + 2)...].contains("dark")
        let arranging = args[(idx + 2)...].contains("arrange")
        let overflow = args[(idx + 2)...].contains("overflow")
        let tab = args[(idx + 2)...].compactMap(SettingsTab.init(rawValue:)).first ?? .general
        SettingsSnapshot.capture(to: args[idx + 1], dark: dark, arranging: arranging, overflow: overflow, tab: tab)
        exit(0)
    }
    // Flux --snapshot-notch <path> [dark] [collapsed|activity|expanded|lockscreen]
    // Flux --snapshot-notch <dir> all [dark]   (CI batch mode — see NotchSnapshot.captureAll)
    if let idx = args.firstIndex(of: "--snapshot-notch"), idx + 1 < args.count {
        let dark = args[(idx + 2)...].contains("dark")
        if args[(idx + 2)...].contains("all") {
            NotchSnapshot.captureAll(to: args[idx + 1], dark: dark)
        } else {
            // M9: "lockscreen" added alongside the pre-existing three —
            // `NotchSnapshot.capture(to:dark:state:)` already special-cases it
            // (see that function's own doc comment), but this allowed-state
            // list gates whether the flag ever reaches that dispatch at all;
            // without it here, `--snapshot-notch out.png lockscreen` silently
            // fell back to "collapsed" instead.
            let state = ["collapsed", "activity", "expanded", "lockscreen"].first { args[(idx + 2)...].contains($0) } ?? "collapsed"
            NotchSnapshot.capture(to: args[idx + 1], dark: dark, state: state)
        }
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
