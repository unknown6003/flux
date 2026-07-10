import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let arranger = MenuBarArranger()
    private let updater = UpdateChecker()
    private var menuBar: MenuBarManager?
    private let hotkey = HotkeyManager()
    private var updateTimer: Timer?
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, arranger: arranger, updater: updater)
    private lazy var arrangeHint = ArrangeHintWindowController(
        arranger: arranger,
        showAlwaysHidden: { [settings] in settings.showAlwaysHiddenSection }
    )
    // Glows the notch when icons are clipped behind it; clicking opens the drawer.
    private lazy var notchHighlight = NotchHighlightWindowController(
        arranger: arranger,
        onActivate: { [arranger] in arranger.setArranging(true) }
    )
    private var cancellables = Set<AnyCancellable>()
    private var settingsVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.menuBar.info("Flux launching")

        menuBar = MenuBarManager(settings: settings, arranger: arranger) { [weak self] in
            self?.openSettings()
        }

        // Reconcile the login-item registration with the saved preference. The OS
        // is the source of truth, so push the actual state back into settings.
        settings.launchAtLogin = LoginItemManager.setEnabled(settings.launchAtLogin)

        configureHotkey()
        configureUpdateChecks()
        observeSettings()
    }

    // MARK: Settings reactions

    private func observeSettings() {
        settings.$launchAtLogin
            .dropFirst()
            .sink { enabled in
                _ = LoginItemManager.setEnabled(enabled)
            }
            .store(in: &cancellables)

        settings.$enableHotkey
            .dropFirst()
            .sink { [weak self] _ in self?.configureHotkey() }
            .store(in: &cancellables)

        settings.$automaticUpdateChecks
            .dropFirst()
            .sink { [weak self] _ in self?.configureUpdateChecks() }
            .store(in: &cancellables)

        // Track the Settings window so we can suppress the floating hint while
        // it's open — Settings already shows the same arrange guidance.
        settingsWindow.onVisibilityChanged = { [weak self] visible in
            self?.settingsVisible = visible
            self?.refreshArrangeHint()
        }

        // Float the "how to arrange" hint next to the menu bar whenever Arrange
        // Mode is on, from wherever it was toggled (menu or Settings).
        arranger.$isArranging
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshArrangeHint() }
            .store(in: &cancellables)

        // Instantiate the notch highlight so it starts observing overflow. It shows
        // and hides itself from the arranger's `notchOverflow` state.
        _ = notchHighlight
    }

    /// The floating arrange hint is redundant while Settings is open — that
    /// window already spells out the same gesture — so only float it when
    /// arranging *and* Settings is closed.
    private func refreshArrangeHint() {
        if arranger.isArranging && !settingsVisible {
            arrangeHint.show()
        } else {
            arrangeHint.hide()
        }
    }

    private func configureHotkey() {
        hotkey.onTrigger = { [weak self] in self?.menuBar?.toggleReveal() }
        if settings.enableHotkey {
            hotkey.register()
        } else {
            hotkey.unregister()
        }
    }

    // MARK: Software update

    /// Poll GitHub for a newer Flux when automatic checks are on: a quiet check a
    /// few seconds after launch (so it never delays startup), then every 6 hours.
    /// Turning the preference off cancels the timer. Manual checks from Settings
    /// are independent of this schedule.
    private func configureUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard settings.automaticUpdateChecks else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.settings.automaticUpdateChecks else { return }
            self.updater.checkForUpdates(userInitiated: false)
        }

        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updater.checkForUpdates(userInitiated: false) }
        }
    }

    // MARK: Settings window

    func openSettings() {
        settingsWindow.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }
}
