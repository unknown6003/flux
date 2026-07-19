import SwiftUI
import AppKit

/// Captures the *real* settings UI — including genuine AppKit controls
/// (NSSwitch, NSSlider, NSSegmentedControl) — via `OffscreenRender`'s shared
/// off-screen-window + `cacheDisplay(in:to:)` pipeline. No Screen Recording
/// permission required.
///
///   Flux --snapshot <path> [light|dark] [arrange] [overflow]
@MainActor
enum SettingsSnapshot {
    static func capture(to path: String, dark: Bool, arranging: Bool = false, overflow: Bool = false,
                        tab: SettingsTab = .general) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        app.appearance = appearance

        let store = SettingsStore()
        // Optionally capture the live Arrange-Mode panel (⌘ callout + zone legend),
        // and its notch-overflow warning state.
        let arranger = MenuBarArranger()
        if arranging { arranger.setArranging(true) }
        if arranging && overflow { arranger.setOverflow(arrange: true, notch: true, iconCount: 4) }
        let root = SettingsView(initialTab: tab)
            .environmentObject(store)
            .environmentObject(arranger)
            .environmentObject(UpdateChecker())
            .environmentObject(NowPlayingService())
            .environmentObject(PermissionCenter())
            .environment(\.colorScheme, dark ? .dark : .light)

        // Settings' width is fixed; only the height needs to fit the tab's
        // content, so measure it from a throwaway hosting view before handing
        // the real capture off to the shared pipeline.
        let probe = NSHostingView(rootView: AnyView(root))
        probe.appearance = appearance
        let fitting = probe.fittingSize
        let size = NSSize(width: 480, height: max(fitting.height, 560))

        OffscreenRender.capture(rootView: AnyView(root), size: size, dark: dark, label: "snapshot", to: path)
    }
}
