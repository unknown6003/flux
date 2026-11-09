import AppKit
import Foundation
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@MainActor private final class SettingsFixtureEffects: SettingsEffects {
    var changes: [SettingsChange] = []
    var failures: [SettingsFailure] = []
    var visits: [String] = []
    func settingsWillShow(_ page: SettingsPage) { visits.append("show." + page.rawValue) }
    func settingsWillHide(_ page: SettingsPage) { visits.append("hide." + page.rawValue) }
    func loginStatus() -> LoginStatus { .disabled }
    func shortcutConflict(_ role: ShortcutRole) -> ShortcutConflict { .clear }
    func updateStatus() -> UpdateStatus { .idle }
    func permissionRows() -> [PermissionRow] { [] }
    func notchAccess(_ kind: NotchAccessKind) -> NotchAccessStatus { .notAsked }
    func lockScreenCapability() -> LockScreenCapability { .unavailable }
    func lockScreenFailureCode() -> String? { nil }
    func crashNotice() -> CrashNotice { .none }
    func menuBarState() -> MenuBarPageState { .init(mode: .paused) }
    func apply(_ change: SettingsChange) { changes.append(change) }
    func report(_ failure: SettingsFailure) { failures.append(failure) }
    private func unexpected() { Issue.record("An unrelated platform effect ran from a preference action") }
    func setLoginItem(_ enabled: Bool) throws -> LoginStatus { unexpected(); return .disabled }
    func openLoginItemsSettings() { unexpected() }
    func replaceShortcut(_ role: ShortcutRole, with shortcut: Shortcut) -> Bool { unexpected(); return false }
    func checkForUpdates() { unexpected() }
    func installUpdate() { unexpected() }
    func openPermissionSettings(_ kind: PermissionKind) { unexpected() }
    func requestNotchAccess(_ kind: NotchAccessKind) { unexpected() }
    func openNotchAccessSettings(_ kind: NotchAccessKind) { unexpected() }
    func setClipboardPersistence(_ enabled: Bool) async throws { unexpected() }
    func clearClipboardHistory() async throws { unexpected() }
    func openLockScreenSettings() { unexpected() }
    func checkLockScreenAgain() { unexpected() }
    func copyDiagnosticReport() -> Bool { unexpected(); return false }
    func dismissCrashNotice() { unexpected() }
    func openMediaRemoteAdapterLicense() { unexpected() }
    func openSourceRepository() { unexpected() }
    func assign(_ application: ApplicationID, to group: MenuBarGroup) { unexpected() }
    func beginArrange() { unexpected() }
    func endArrange() { unexpected() }
    func showRealIcons() { unexpected() }
    func refreshMenuBar() { unexpected() }
    func openAccessibilitySettings() { unexpected() }
    func checkAccessibility() { unexpected() }
    func reviewIdentity(_ application: ApplicationID) { unexpected() }
    func setCompactSpacing(_ enabled: Bool) { unexpected() }
    func moveMenuBarItem(_ move: MenuBarItemMove) { unexpected() }
}

@Suite(.serialized)
struct SettingsCoordinatorTests {
    @MainActor fileprivate static func find(_ id: String) -> NSView? {
        @MainActor func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap(walk).first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(walk) }.first
    }

    @Test @MainActor func realSettingsControlsSaveBeforeApplyingAndRefreshWithoutEffects() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        enum UnexpectedAnalytics: Error { case constructed }
        let usage = UsageCollection(defaults: defaults) { _ in
            Issue.record("Analytics was constructed by opening Settings")
            throw UnexpectedAnalytics.constructed
        }
        let effects = SettingsFixtureEffects()
        let settings = SettingsCoordinator(preferences: preferences, usage: usage,
                                           version: .init(), effects: effects)
        defer { settings.close() }
        settings.show(.general)
        #expect(effects.visits == ["show.general"])
        #expect(effects.changes.isEmpty)
        let hotkeys = try #require(Self.find("general.hotkeys") as? NSSwitch)
        hotkeys.state = .off
        _ = hotkeys.sendAction(hotkeys.action, to: hotkeys.target)
        #expect(!preferences.value(for: Preferences.enableHotkey))
        #expect(effects.changes.count == 1)
        if case .some(.hotkeysEnabled(false)) = effects.changes.first {} else { Issue.record("Wrong runtime effect") }
        settings.refresh()
        #expect(effects.changes.count == 1)

        settings.show(.notch)
        #expect(effects.visits == ["show.general", "hide.general", "show.notch"])
        let clipboard = try #require(Self.find("notch.widget.clipboard") as? NSSwitch)
        #expect(clipboard.state == .off)
        clipboard.state = .on
        _ = clipboard.sendAction(clipboard.action, to: clipboard.target)
        #expect(preferences.value(for: Preferences.clipboardEnabled))
        #expect(!preferences.value(for: Preferences.clipboardPersistenceEnabled))
        #expect(effects.changes.count == 2)
        if case .some(.features(let config)) = effects.changes.last {
            #expect(config.enabledWidgets.contains(.clipboard))
        } else { Issue.record("Clipboard did not update service demand") }
        #expect(effects.failures.isEmpty)
        #expect(!usage.enabled)
        #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)
        settings.close()
        #expect(effects.visits.last == "hide.notch")
    }

    @Test func widgetOrderMovesKnownNeighborsWithoutDiscardingFutureIDs() {
        var order = WidgetOrder(saved: ["future.first", "mirror", "future.middle", "shelf", "mirror", "calendar"])
        let moved = order.move(.shelf, up: true)
        #expect(moved)
        #expect(order.saved.prefix(4) == ["future.first", "shelf", "future.middle", "mirror"])
        #expect(order.widgets == [.shelf, .mirror, .calendar, .nowPlaying, .clipboard])
        let movedPastFirst = order.move(.shelf, up: true)
        #expect(!movedPastFirst)
    }
}
