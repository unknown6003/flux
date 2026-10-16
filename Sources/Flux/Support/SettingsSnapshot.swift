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

        let suite = "com.flux.settings-snapshot." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        if tab == .menuBar { store.showAlwaysHiddenSection = true }
        // Optionally capture the live Arrange-Mode panel (⌘ callout + zone legend),
        // and its notch-overflow warning state.
        let arranger = MenuBarArranger()
        let iconManager = MenuBarIconManager()
        if arranging { arranger.setArranging(true) }
        if arranging && overflow { arranger.setOverflow(arrange: true, notch: true, iconCount: 4) }
        let root = SettingsView(initialTab: tab)
            .environmentObject(store)
            .environmentObject(arranger)
            .environmentObject(iconManager)
            .environmentObject(UpdateChecker())
            .environmentObject(NowPlayingService())
            .environmentObject(PermissionCenter())
            .environmentObject(ClipboardMonitor())
            // A fresh reporter has no previous session on disk to read (it
            // never calls `beginSession()`), so the crash card renders as
            // absent — which is what a clean screenshot should show.
            .environmentObject(CrashReporter())
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.menuBarSnapshotIcons, tab == .menuBar ? Self.menuBarIcons : nil)

        OffscreenRender.capture(rootView: AnyView(root),
                                size: SettingsView.designSize,
                                dark: dark,
                                label: "snapshot",
                                to: path)
    }
}

private struct MenuBarSnapshotIconsKey: EnvironmentKey {
    static let defaultValue: [MenuBarIconManager.Icon]? = nil
}

extension EnvironmentValues {
    var menuBarSnapshotIcons: [MenuBarIconManager.Icon]? {
        get { self[MenuBarSnapshotIconsKey.self] }
        set { self[MenuBarSnapshotIconsKey.self] = newValue }
    }
}

extension SettingsSnapshot {
    static var menuBarIcons: [MenuBarIconManager.Icon] {
        [("com.apple.Safari", "Safari", MenuBarSection.shown),
         ("com.apple.finder", "Finder", .shown),
         ("com.apple.Notes", "Notes", .hidden),
         ("com.apple.calculator", "Calculator", .hidden),
         ("com.apple.Terminal", "Terminal", .alwaysHidden)].map { bundle, title, section in
            MenuBarIconManager.Icon(id: bundle + "|0", title: title, source: title,
                                    section: section, isMovable: true, frame: .zero)
        }
    }
}
