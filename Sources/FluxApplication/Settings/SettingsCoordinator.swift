import AppKit
import FluxCore
import FluxUI

/// Builds the Settings window and its five pages from saved values, and maps
/// every page action to a saved key or a required `SettingsEffects` call.
///
/// Ownership: the app owns `PreferenceStore`, `UsageCollection`, the
/// repositories and the effects object, and keeps this coordinator. The
/// coordinator owns the window controller while it is open and holds the one
/// visible page weakly. Settings discards a page on a page switch or close.
///
/// `effects` is unowned, so the effects object may own this coordinator. It
/// must outlive it. Page closures and tasks capture the coordinator weakly.
@MainActor
public final class SettingsCoordinator {
    private let preferences: PreferenceStore
    private let usage: UsageCollection
    private let version: ApplicationVersion
    private unowned let effects: any SettingsEffects

    private var window: SettingsWindowController?
    private weak var page: NSViewController?

    // Per-visit results. Cleared when the page goes away.
    private var shortcutRejections: [ShortcutRole: ShortcutConflict] = [:]
    private var analyticsWorking = 0
    private var analyticsWasReset = false
    private var diagnostics: DiagnosticStatus = .ready

    // Keep async work in request order.
    private var analyticsTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?

    public init(preferences: PreferenceStore, usage: UsageCollection,
                version: ApplicationVersion, effects: any SettingsEffects) {
        self.preferences = preferences
        self.usage = usage
        self.version = version
        self.effects = effects
    }

    /// Opens Settings on `page`, or on the current page when nil. Bind ⌘, here.
    public func show(_ page: SettingsPage? = nil) {
        if let window {
            window.show(page)
            return
        }
        let controller = SettingsWindowController(initialPage: page ?? .general) { [weak self] page in
            self?.makePage(page) ?? NSViewController()
        }
        controller.onPageWillDisappear = { [weak self] page in
            self?.effects.settingsWillHide(page)
            self?.pageWillDisappear()
        }
        controller.onClose = { [weak self] in self?.window = nil }
        window = controller
        controller.show(nil)
    }

    public func close() { window?.close() }

    /// Rebuilds the state of the visible page only. Call it after an effect
    /// result, a permission change, an update status or a menu bar read.
    /// It does nothing while Settings is closed.
    public func refresh() {
        guard let current = window?.currentPage, let page else { return }
        switch current {
        case .general: (page as? GeneralPreferencesController)?.update(state: generalState())
        case .menuBar: (page as? MenuBarPreferencesController)?.update(menuBarState())
        case .notch: (page as? NotchPreferencesController)?.update(state: notchState())
        case .lockScreen: (page as? LockScreenPreferencesController)?.update(state: lockScreenState())
        case .about: (page as? AboutPreferencesController)?.update(state: aboutState())
        }
    }

    // MARK: Pages

    private func makePage(_ kind: SettingsPage) -> NSViewController {
        effects.settingsWillShow(kind)
        let controller: NSViewController
        switch kind {
        case .general:
            controller = GeneralPreferencesController(state: generalState()) { [weak self] in self?.handle($0) }
        case .menuBar:
            controller = MenuBarPreferencesController(state: menuBarState(), actions: menuBarActions())
        case .notch:
            controller = NotchPreferencesController(state: notchState()) { [weak self] in self?.handle($0) }
        case .lockScreen:
            controller = LockScreenPreferencesController(state: lockScreenState()) { [weak self] in self?.handle($0) }
        case .about:
            controller = AboutPreferencesController(state: aboutState()) { [weak self] in self?.handle($0) }
        }
        page = controller
        return controller
    }

    private func pageWillDisappear() {
        page = nil
        shortcutRejections = [:]
        analyticsWasReset = false
        diagnostics = .ready
    }

    // MARK: State

    private func generalState() -> GeneralPreferencesState {
        let hotkeys = value(Preferences.enableHotkey)
        return GeneralPreferencesState(
            launchAtLoginRequested: value(Preferences.launchAtLogin),
            loginStatus: effects.loginStatus(),
            hotkeysEnabled: hotkeys,
            revealShortcut: shortcut(.reveal),
            revealConflict: conflict(.reveal, hotkeys: hotkeys),
            notchShortcut: shortcut(.notch),
            notchConflict: conflict(.notch, hotkeys: hotkeys),
            appearance: value(Preferences.appearance),
            automaticUpdateChecks: value(Preferences.automaticUpdateChecks),
            update: effects.updateStatus(),
            analytics: analyticsStatus,
            permissions: effects.permissionRows()
        )
    }

    private var analyticsStatus: AnalyticsStatus {
        if analyticsWorking > 0 { return .working }
        if analyticsWasReset { return .reset }
        return usage.enabled ? .on : .off
    }

    private func conflict(_ role: ShortcutRole, hotkeys: Bool) -> ShortcutConflict {
        if let rejected = shortcutRejections[role] { return rejected }
        return hotkeys ? effects.shortcutConflict(role) : .clear
    }

    private func menuBarState() -> MenuBarPageState {
        var state = effects.menuBarState()
        state.alwaysHiddenEnabled = value(Preferences.alwaysHiddenEnabled)
        state.options.autoRehide = value(Preferences.autoRehide)
        state.options.autoRehideDelay = value(Preferences.autoRehideDelay)
        state.options.iconStyle = value(Preferences.iconStyle)
        return state
    }

    private func notchState() -> NotchPreferencesState {
        let order = WidgetOrder(saved: value(Preferences.widgetOrder))
        let expiry = Int(exactly: value(Preferences.shelfExpiryDays)).flatMap(ShelfExpiry.init(rawValue:)) ?? .never
        return NotchPreferencesState(
            isEnabled: value(Preferences.notchEnabled),
            trigger: value(Preferences.expansionTrigger),
            hoverCloseDelay: value(Preferences.hoverCloseDelay),
            showInFullscreen: value(Preferences.showInFullscreen),
            widgets: order.widgets.map { WidgetPreference(widget: $0, isEnabled: value(Self.key(for: $0))) },
            duoEnabled: value(Preferences.duoEnabled),
            shelfExpiry: expiry,
            clipboardSaving: value(Preferences.clipboardPersistenceEnabled),
            enabledActivities: Set(NotchActivity.allCases.filter { value(Self.key(for: $0)) }),
            calendarAccess: effects.notchAccess(.calendar),
            cameraAccess: effects.notchAccess(.camera),
            accessibilityAccess: effects.notchAccess(.accessibility)
        )
    }

    private func lockScreenState() -> LockScreenPreferencesState {
        LockScreenPreferencesState(
            isEnabled: value(Preferences.lockScreenEnabled),
            showsNowPlaying: value(Preferences.lockScreenNowPlaying),
            showsActivities: value(Preferences.lockScreenActivities),
            playsUnlockSound: value(Preferences.lockScreenUnlockSound),
            capability: effects.lockScreenCapability(),
            failureCode: effects.lockScreenFailureCode()
        )
    }

    private func aboutState() -> AboutPreferencesState {
        AboutPreferencesState(
            version: version.version,
            build: version.build,
            update: effects.updateStatus(),
            diagnostics: diagnostics,
            crashNotice: effects.crashNotice()
        )
    }

    // MARK: General actions

    private func handle(_ action: GeneralPreferencesAction) {
        switch action {
        case .setLaunchAtLogin(let enabled):
            // Save the choice, then ask macOS. The page shows the fresh system status.
            if save(enabled, Preferences.launchAtLogin) {
                do { _ = try effects.setLoginItem(enabled) } catch { effects.report(.loginItemFailed) }
            }
        case .openLoginItems:
            effects.openLoginItemsSettings()
        case .setHotkeysEnabled(let enabled):
            shortcutRejections = [:]
            save(enabled, Preferences.enableHotkey, then: .hotkeysEnabled(enabled))
        case .setRevealShortcut(let shortcut):
            setShortcut(shortcut, for: .reveal)
        case .setNotchShortcut(let shortcut):
            setShortcut(shortcut, for: .notch)
        case .setAppearance(let appearance):
            save(appearance, Preferences.appearance, then: .appearance(appearance))
        case .setAutomaticUpdateChecks(let enabled):
            save(enabled, Preferences.automaticUpdateChecks, then: .automaticUpdateChecks(enabled))
        case .checkForUpdates:
            effects.checkForUpdates()
        case .installUpdate:
            effects.installUpdate()
        case .setAnalyticsEnabled(let enabled):
            runAnalytics { usage in await usage.setEnabled(enabled) }
        case .resetAnalyticsID:
            runAnalytics { usage in await usage.resetIdentity() }
            analyticsWasReset = true
        case .openPermissionSettings(let kind):
            effects.openPermissionSettings(kind)
        }
        refresh()
    }

    private func setShortcut(_ shortcut: Shortcut, for role: ShortcutRole) {
        let other: ShortcutRole = role == .reveal ? .notch : .reveal
        if shortcut == self.shortcut(other) {
            shortcutRejections[role] = .otherFluxShortcut
            return
        }
        let previous = self.shortcut(role)
        guard shortcut != previous else {
            shortcutRejections[role] = nil
            return
        }
        let live = value(Preferences.enableHotkey)
        // The effect keeps the old chord working when macOS refuses the new one.
        if live, !effects.replaceShortcut(role, with: shortcut) {
            shortcutRejections[role] = .unavailable
            return
        }
        let keys = Self.keys(for: role)
        do {
            try preferences.set(shortcut.keyCode, for: keys.code)
            do {
                try preferences.set(shortcut.carbonModifiers, for: keys.modifiers)
            } catch {
                try? preferences.set(previous.keyCode, for: keys.code)
                throw error
            }
            shortcutRejections[role] = nil
        } catch {
            effects.report(.saveFailed)
            // Put the saved chord back in the live registration.
            if live, !effects.replaceShortcut(role, with: previous) {
                shortcutRejections[role] = .unavailable
            }
        }
    }

    /// Runs one UsageCollection change after the previous one finished.
    private func runAnalytics(_ work: @escaping @Sendable @MainActor (UsageCollection) async -> Void) {
        let previous = analyticsTask
        let usage = usage
        analyticsWorking += 1
        analyticsWasReset = false
        analyticsTask = Task { @MainActor [weak self] in
            await previous?.value
            await work(usage)
            guard let self else { return }
            self.analyticsWorking -= 1
            self.refresh()
        }
    }

    // MARK: Menu Bar actions

    private func menuBarActions() -> MenuBarPageActions {
        MenuBarPageActions(
            assign: { [weak self] id, group in self?.effects.assign(id, to: group) },
            beginArrange: { [weak self] in self?.effects.beginArrange() },
            endArrange: { [weak self] in self?.effects.endArrange() },
            showRealIcons: { [weak self] in self?.effects.showRealIcons() },
            refresh: { [weak self] in self?.effects.refreshMenuBar() },
            openAccessibilitySettings: { [weak self] in self?.effects.openAccessibilitySettings() },
            checkAccessibility: { [weak self] in self?.effects.checkAccessibility() },
            reviewIdentity: { [weak self] id in self?.effects.reviewIdentity(id) },
            setOption: { [weak self] in self?.handle($0) }
        )
    }

    private func handle(_ action: MenuBarOptionAction) {
        switch action {
        case .setAlwaysHiddenEnabled(let enabled):
            save(enabled, Preferences.alwaysHiddenEnabled, then: .menuBarOptions)
        case .setAutoRehide(let enabled):
            save(enabled, Preferences.autoRehide, then: .menuBarOptions)
        case .setAutoRehideDelay(let seconds):
            save(min(max(seconds, 2), 30), Preferences.autoRehideDelay, then: .menuBarOptions)
        case .setIconStyle(let style):
            save(style, Preferences.iconStyle, then: .menuBarOptions)
        case .setCompactSpacing(let enabled):
            effects.setCompactSpacing(enabled)
        }
        refresh()
    }

    // MARK: Notch actions

    private func handle(_ action: NotchPreferencesAction) {
        switch action {
        case .setEnabled(let enabled):
            saveFeature(enabled, Preferences.notchEnabled)
        case .setTrigger(let trigger):
            save(trigger, Preferences.expansionTrigger, then: .presentation)
        case .setHoverCloseDelay(let seconds):
            save(max(seconds, 0), Preferences.hoverCloseDelay, then: .presentation)
        case .setShowInFullscreen(let enabled):
            save(enabled, Preferences.showInFullscreen, then: .presentation)
        case .setWidgetEnabled(let widget, let enabled):
            saveFeature(enabled, Self.key(for: widget))
        case .moveWidgetUp(let widget):
            move(widget, up: true)
        case .moveWidgetDown(let widget):
            move(widget, up: false)
        case .setDuoEnabled(let enabled):
            saveFeature(enabled, Preferences.duoEnabled)
        case .setShelfExpiry(let expiry):
            save(Double(expiry.rawValue), Preferences.shelfExpiryDays, then: .presentation)
        case .setClipboardSaving(let enabled):
            setClipboardSaving(enabled)
        case .clearClipboardHistory:
            runClipboard { effects in
                do { try await effects.clearClipboardHistory() } catch { effects.report(.clipboardFailed) }
            }
        case .setActivity(let activity, let enabled):
            if activity == .timer {
                save(enabled, Self.key(for: activity), then: .presentation)
            } else {
                saveFeature(enabled, Self.key(for: activity))
            }
        case .requestAccess(let kind):
            effects.requestNotchAccess(kind)
        case .openAccessSettings(let kind):
            effects.openNotchAccessSettings(kind)
        }
        refresh()
    }

    private func move(_ widget: Widget, up: Bool) {
        var order = WidgetOrder(saved: value(Preferences.widgetOrder))
        guard order.move(widget, up: up) else { return }
        save(order.saved, Preferences.widgetOrder, then: .presentation)
    }

    /// Changes the repository first, then saves. A failed save puts the
    /// repository back, so the saved switch always matches the file state.
    private func setClipboardSaving(_ enabled: Bool) {
        runClipboard { [weak self] effects in
            do {
                try await effects.setClipboardPersistence(enabled)
            } catch {
                effects.report(.clipboardFailed)
                return
            }
            guard let self else { return }
            if !self.save(enabled, Preferences.clipboardPersistenceEnabled) {
                do { try await effects.setClipboardPersistence(!enabled) } catch { effects.report(.clipboardFailed) }
            }
        }
    }

    private func runClipboard(_ work: @escaping @Sendable @MainActor (any SettingsEffects) async -> Void) {
        let previous = clipboardTask
        let effects = effects
        clipboardTask = Task { @MainActor [weak self] in
            await previous?.value
            await work(effects)
            self?.refresh()
        }
    }

    // MARK: Lock Screen and About actions

    private func handle(_ action: LockScreenPreferencesAction) {
        switch action {
        case .setEnabled(let enabled): saveFeature(enabled, Preferences.lockScreenEnabled)
        case .setNowPlaying(let enabled): saveFeature(enabled, Preferences.lockScreenNowPlaying)
        case .setActivities(let enabled): saveFeature(enabled, Preferences.lockScreenActivities)
        case .setUnlockSound(let enabled): save(enabled, Preferences.lockScreenUnlockSound, then: .presentation)
        case .openSystemSettings: effects.openLockScreenSettings()
        case .checkAgain: effects.checkLockScreenAgain()
        }
        refresh()
    }

    private func handle(_ action: AboutPreferencesAction) {
        switch action {
        case .checkForUpdates: effects.checkForUpdates()
        case .installUpdate: effects.installUpdate()
        case .copyDiagnosticReport: diagnostics = effects.copyDiagnosticReport() ? .copied : .unavailable
        case .dismissCrashNotice: effects.dismissCrashNotice()
        case .openMediaRemoteAdapterLicense: effects.openMediaRemoteAdapterLicense()
        case .openSourceRepository: effects.openSourceRepository()
        }
        refresh()
    }

    // MARK: Store

    private func value<Value>(_ preference: Preference<Value>) -> Value {
        preferences.value(for: preference)
    }

    /// Saves one key. On success it sends `change`. On failure it reports a
    /// fixed code and the saved value stays as it was.
    @discardableResult
    private func save<Value>(_ value: Value, _ preference: Preference<Value>,
                             then change: @autoclosure () -> SettingsChange? = nil) -> Bool {
        do {
            try preferences.set(value, for: preference)
        } catch {
            effects.report(.saveFailed)
            return false
        }
        if let change = change() { effects.apply(change) }
        return true
    }

    private func saveFeature(_ value: Bool, _ preference: Preference<Bool>) {
        save(value, preference, then: .features(FeatureConfiguration(preferences: preferences)))
    }

    private func shortcut(_ role: ShortcutRole) -> Shortcut {
        let keys = Self.keys(for: role)
        return Shortcut(keyCode: value(keys.code), carbonModifiers: value(keys.modifiers))
    }

    private static func keys(for role: ShortcutRole) -> (code: Preference<UInt32>, modifiers: Preference<UInt32>) {
        switch role {
        case .reveal: (Preferences.hotkeyKeyCode, Preferences.hotkeyModifiers)
        case .notch: (Preferences.notchHotkeyKeyCode, Preferences.notchHotkeyModifiers)
        }
    }

    private static func key(for widget: Widget) -> Preference<Bool> {
        switch widget {
        case .nowPlaying: Preferences.nowPlayingEnabled
        case .shelf: Preferences.shelfEnabled
        case .calendar: Preferences.calendarEnabled
        case .mirror: Preferences.mirrorEnabled
        case .clipboard: Preferences.clipboardEnabled
        }
    }

    private static func key(for activity: NotchActivity) -> Preference<Bool> {
        switch activity {
        case .battery: Preferences.batteryEnabled
        case .bluetooth: Preferences.bluetoothEnabled
        case .calendarEvent: Preferences.calendarEventEnabled
        case .timer: Preferences.timerEnabled
        case .soundHUD: Preferences.soundHUDEnabled
        }
    }
}
