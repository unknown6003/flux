import FluxCore
import FluxUI

/// One of the two Flux global shortcuts.
public enum ShortcutRole: Hashable, Sendable {
    /// `flux.hotkey.*`. Reveals hidden menu bar icons.
    case reveal
    /// `flux.notch.hotkey.*`. Opens the notch.
    case notch
}

/// A saved change that the app must apply at run time. The coordinator sends
/// it only after `PreferenceStore.set` succeeded.
public enum SettingsChange: Sendable {
    case hotkeysEnabled(Bool)
    case appearance(Appearance)
    case automaticUpdateChecks(Bool)
    /// Always Hidden, auto-rehide, delay or icon style. Read them from the store.
    case menuBarOptions
    /// A display value with no live service: notch trigger, close delay,
    /// fullscreen, widget order, shelf expiry, timer display or unlock sound.
    /// Read the new value from the store.
    case presentation
    /// A switch that changes which live services run. Pass it to `FeatureDemand`.
    case features(FeatureConfiguration)
}

/// A fixed failure the app shows or counts. It holds no user content, path or OS text.
public enum SettingsFailure: String, Sendable {
    /// `PreferenceStore.set` threw. The saved value did not change.
    case saveFailed = "settings.save"
    /// The login item call threw. The page shows the fresh system status.
    case loginItemFailed = "settings.login"
    /// The clipboard repository refused a persistence change or a clear.
    case clipboardFailed = "settings.clipboard"
}

/// Platform work and fresh system readings that Settings needs from the app.
///
/// Every method is required. There is no default, so a missing feature is a
/// compile error and not a silent no-op. The coordinator calls each method
/// on the main actor only from a user action or a page refresh. None of them
/// may show a macOS permission prompt unless the method name says "request".
@MainActor
public protocol SettingsEffects: AnyObject, Sendable {
    // MARK: Fresh readings. Each call reads now. Do not cache across actions.

    /// `LoginItem.state`, mapped to the UI type.
    func loginStatus() -> LoginStatus
    /// The registration result of the saved chord. `.clear` when hotkeys are off.
    func shortcutConflict(_ role: ShortcutRole) -> ShortcutConflict
    func updateStatus() -> UpdateStatus
    /// Rows for General › Permissions, in display order. Status reads only.
    func permissionRows() -> [PermissionRow]
    func notchAccess(_ kind: NotchAccessKind) -> NotchAccessStatus
    /// The probe result. The coordinator never assumes `.available`.
    func lockScreenCapability() -> LockScreenCapability
    /// A fixed code from the last failed lock screen attempt, or nil.
    func lockScreenFailureCode() -> String?
    func crashNotice() -> CrashNotice
    /// Inventory, mode and arrange state. The coordinator replaces
    /// `alwaysHiddenEnabled` and the saved `options` fields with store values,
    /// and keeps `options.compactSpacing` from this value.
    func menuBarState() -> MenuBarPageState

    // MARK: Runtime apply

    /// Called after a successful save. Apply the change to running features.
    func apply(_ change: SettingsChange)
    /// Called once per failed step. Show or count the fixed code only.
    func report(_ failure: SettingsFailure)

    // MARK: General

    /// Call `LoginItem.setEnabled` and return the fresh state. Throw on failure.
    func setLoginItem(_ enabled: Bool) throws -> LoginStatus
    func openLoginItemsSettings()
    /// Replace the live registration for `role`. Return true only when the new
    /// chord is registered. On false, the previous chord must still work.
    /// Called only while hotkeys are on.
    func replaceShortcut(_ role: ShortcutRole, with shortcut: Shortcut) -> Bool
    /// Start a check. Call `SettingsCoordinator.refresh()` when the status changes.
    func checkForUpdates()
    func installUpdate()
    /// Open the System Settings pane. Never prompt.
    func openPermissionSettings(_ kind: PermissionKind)

    // MARK: Notch

    /// The user pressed Allow. This may show the macOS prompt.
    func requestNotchAccess(_ kind: NotchAccessKind)
    func openNotchAccessSettings(_ kind: NotchAccessKind)
    /// `ClipboardRepository.setPersistenceEnabled`. Throw when it refused.
    func setClipboardPersistence(_ enabled: Bool) async throws
    /// `ClipboardRepository.clear`. Throw when it refused.
    func clearClipboardHistory() async throws

    // MARK: Lock Screen

    func openLockScreenSettings()
    /// Run the probe again, then call `SettingsCoordinator.refresh()`.
    func checkLockScreenAgain()

    // MARK: About

    /// Copy fixed status lines. Return true only after the pasteboard accepted them.
    func copyDiagnosticReport() -> Bool
    /// Save that the notice was dismissed, so `crashNotice()` returns `.none`.
    func dismissCrashNotice()
    func openMediaRemoteAdapterLicense()
    func openSourceRepository()

    // MARK: Menu Bar. Each result arrives as a later `refresh()`.

    func assign(_ application: ApplicationID, to group: MenuBarGroup)
    func beginArrange()
    func endArrange()
    /// The user asked for real icons. The app owns Screen Recording.
    func showRealIcons()
    func refreshMenuBar()
    func openAccessibilitySettings()
    func checkAccessibility()
    func reviewIdentity(_ application: ApplicationID)
    /// Compact spacing has no Core key. The app owns the macOS value.
    func setCompactSpacing(_ enabled: Bool)
}
