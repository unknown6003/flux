import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let arranger = MenuBarArranger()
    private var menuBar: MenuBarManager?
    private let hotkey = HotkeyManager()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, arranger: arranger)
    private lazy var arrangeHint = ArrangeHintWindowController(
        arranger: arranger,
        showAlwaysHidden: { [settings] in settings.showAlwaysHiddenSection }
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

    // MARK: Settings window

    func openSettings() {
        settingsWindow.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }
}
