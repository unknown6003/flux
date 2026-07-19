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

    // Notch suite: one panel/state-machine controller plus the Now Playing
    // service + widget it hosts for M1, and the File Shelf store + widget
    // added in M2.
    private let notchWindow = NotchWindowController()
    private let nowPlayingService = NowPlayingService()
    private lazy var nowPlayingWidget = NowPlayingWidget(
        service: nowPlayingService, isEnabled: settings.notchNowPlayingEnabled)
    private let shelfStore = ShelfStore()
    private lazy var shelfWidget = ShelfWidget(
        store: shelfStore, isEnabled: settings.notchShelfEnabled)
    // Unified TCC status/request center — first consumer is Calendar (M4);
    // M5 (Accessibility) and M6 (Camera) reuse the same instance.
    private let permissionCenter = PermissionCenter()
    // EventKit is owned here, shared between `calendarWidget` (the agenda
    // UI, read-only) and `notchActivityRouter` (the event-soon live
    // activity, and the SOLE caller of `start()`/`stop()` — see
    // `CalendarService`'s own doc comment on that ownership fix).
    private let calendarService = CalendarService()
    private lazy var calendarWidget = CalendarWidget(
        service: calendarService, permissions: permissionCenter, isEnabled: settings.notchCalendarEnabled)
    // Single home for every live-activity *producer* (menu-bar overflow,
    // battery, Bluetooth, calendar, volume/brightness HUD) — see
    // `NotchActivityRouter`'s own doc comment for why this replaced the ad
    // hoc per-producer Combine sink that used to live directly on this
    // class. `lazy` (like the widgets
    // above) because its initializer reads sibling instance properties
    // (`notchWindow`, `settings`, `arranger`, `calendarService`,
    // `permissionCenter`), which isn't possible from a plain stored
    // property's default-value expression; forced into existence at launch
    // via the `_ = notchActivityRouter` touch in `configureNotch()`, since
    // nothing else naturally accesses it the way `nowPlayingWidget` is
    // forced via `registry.register(...)`.
    //
    // `viewModel`/`presentation` replace the old `isPresentationAvailable`/
    // `isCalendarWidgetPresented` closures — the router now observes
    // `notchWindow.viewModel.$state` and `notchWindow.$isPresenting`
    // directly (see the router's own doc comment on that M4 fix).
    private lazy var notchActivityRouter = NotchActivityRouter(
        activities: notchWindow.activities, settings: settings, arranger: arranger,
        calendar: calendarService, permissions: permissionCenter, viewModel: notchWindow.viewModel,
        presentation: notchWindow.$isPresenting.eraseToAnyPublisher())

    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, arranger: arranger, updater: updater,
        nowPlaying: nowPlayingService, permissions: permissionCenter)
    private lazy var arrangeHint = ArrangeHintWindowController(
        arranger: arranger,
        showAlwaysHidden: { [settings] in settings.showAlwaysHiddenSection }
    )
    // Glows the notch when icons are clipped behind it; clicking opens the drawer.
    // Only used when the notch panel itself is disabled — see
    // `configureNotchOverflowCoexistence`.
    private var notchHighlight: NotchHighlightWindowController?

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

        notchWindow.registry.register(nowPlayingWidget)
        notchWindow.registry.register(shelfWidget)
        notchWindow.registry.register(calendarWidget)
        notchWindow.artworkProvider = { [weak self] in self?.nowPlayingService.artwork }
        // A file dropped on the *collapsed* notch is caught at the window
        // level (see `NotchPanel`/`NotchWindowController`), which has no
        // knowledge of `ShelfStore` itself — this is the one place that
        // knowledge gap is bridged.
        notchWindow.onShelfDrop = { [weak self] urls in self?.shelfStore.add(urls: urls).count ?? 0 }
        // A tap on the overflow indicator's wings should open Arrange Mode,
        // same as the legacy `NotchHighlightWindowController` glow's
        // `onActivate` — not toggle the notch panel itself, which is what a
        // plain `viewModel.clicked()` would otherwise do for every activity.
        notchWindow.onActivityTap = { [arranger] kind in
            guard kind == .menuBarOverflow else { return false }
            arranger.setArranging(true)
            return true
        }
        // Screen changes (external display connect/disconnect, clamshell
        // open/close) flip `notchWindow.isPresenting` independently of every
        // settings toggle `notchActivityRouter` already reacts to.
        // `notchActivityRouter` observes `notchWindow.$isPresenting` directly
        // (injected at construction above), so no explicit wiring is needed
        // here anymore — it re-applies its monitor start/stop decision (and
        // the calendar-event activity gating) on its own whenever
        // presentation changes, keeping the battery/Bluetooth monitors from
        // running with nowhere left to show a wing (or sitting idle once a
        // notched screen reappears).

        configureHotkey()
        configureNotch()
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

        // Re-register as soon as the user records a new chord, so the field in
        // Settings and the live system hotkey never disagree.
        settings.$hotkeyShortcut
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
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

        observeNotchSettings()
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

    /// Install (or tear down) the global hotkey to match the current preferences, and
    /// push the *actual* outcome back into settings: macOS hands a chord to whichever
    /// app claimed it first, so a registration can legitimately fail. Surfacing that as
    /// `hotkeyConflict` is the only way the user learns their shortcut is dead rather
    /// than assuming Flux is broken.
    private func configureHotkey() {
        hotkey.onTrigger[.menuBarToggle] = { [weak self] in self?.menuBar?.toggleReveal() }
        guard settings.enableHotkey else {
            hotkey.unregister(.menuBarToggle)
            settings.hotkeyConflict = false
            return
        }
        settings.hotkeyConflict = !hotkey.register(settings.hotkeyShortcut, for: .menuBarToggle)
    }

    // MARK: Notch

    /// Push every notch-related preference into the live controller. Called
    /// once at launch (to apply whatever was persisted) and again from each
    /// setting's own Combine sink.
    private func configureNotch() {
        // Applied before `setEnabled` so a fresh panel is built with the
        // right collection behavior from the start, rather than defaulting
        // to `NotchPanel.init`'s always-on `.fullScreenAuxiliary` for one
        // tick and then immediately being corrected.
        notchWindow.setShowInFullscreen(settings.notchShowInFullscreen)
        notchWindow.setEnabled(settings.notchEnabled)
        notchWindow.viewModel.expansionTrigger = settings.notchExpansionTrigger
        notchWindow.viewModel.hoverOpenDelay = settings.notchHoverOpenDelay
        notchWindow.viewModel.hoverCloseDelay = settings.notchHoverCloseDelay
        notchWindow.registry.order = settings.notchWidgetOrder.compactMap(WidgetID.init(rawValue:))
        notchWindow.registry.setEnabled(.nowPlaying, settings.notchNowPlayingEnabled)
        notchWindow.registry.setEnabled(.shelf, settings.notchShelfEnabled)
        notchWindow.registry.setEnabled(.calendar, settings.notchCalendarEnabled)
        shelfStore.expiryInterval = settings.notchShelfExpiryInterval
        configureNotchOverflowCoexistence()
        configureNotchHotkey()
        // Force the lazy router into existence — see its property doc
        // comment for why nothing else naturally touches it. Its own `init`
        // reads the live activity toggles directly, so no further settings
        // plumbing is needed here.
        _ = notchActivityRouter
    }

    private func observeNotchSettings() {
        settings.$notchEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.configureNotch() }
            .store(in: &cancellables)

        settings.$notchExpansionTrigger
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.viewModel.expansionTrigger = value }
            .store(in: &cancellables)

        settings.$notchHoverOpenDelay
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.viewModel.hoverOpenDelay = value }
            .store(in: &cancellables)

        settings.$notchHoverCloseDelay
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.viewModel.hoverCloseDelay = value }
            .store(in: &cancellables)

        settings.$notchShowInFullscreen
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.setShowInFullscreen(value) }
            .store(in: &cancellables)

        settings.$notchWidgetOrder
            .dropFirst()
            .sink { [weak self] value in
                self?.notchWindow.registry.order = value.compactMap(WidgetID.init(rawValue:))
            }
            .store(in: &cancellables)

        settings.$notchNowPlayingEnabled
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.registry.setEnabled(.nowPlaying, value) }
            .store(in: &cancellables)

        settings.$notchShelfEnabled
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.registry.setEnabled(.shelf, value) }
            .store(in: &cancellables)

        settings.$notchCalendarEnabled
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.registry.setEnabled(.calendar, value) }
            .store(in: &cancellables)

        settings.$notchShelfExpiryDays
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.shelfStore.expiryInterval = self.settings.notchShelfExpiryInterval
            }
            .store(in: &cancellables)

        settings.$notchHotkey
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureNotchHotkey() }
            .store(in: &cancellables)
    }

    /// Register (or tear down) the notch toggle hotkey, mirroring
    /// `configureHotkey()`'s pattern for the menu-bar chord. Only meaningful
    /// while the notch feature itself is on — there's nothing to toggle
    /// otherwise.
    private func configureNotchHotkey() {
        // Routed through `NotchWindowController.hotkeyToggled()` (not the
        // view model directly) so it's a no-op while the controller has
        // nothing presenting — the hotkey stays registered even on an
        // external-only clamshell setup with no built-in notched screen,
        // and must not drive a headless expand in that case.
        hotkey.onTrigger[.notchToggle] = { [weak self] in self?.notchWindow.hotkeyToggled() }
        guard settings.notchEnabled, settings.notchHotkey.isValid else {
            hotkey.unregister(.notchToggle)
            settings.notchHotkeyConflict = false
            return
        }
        settings.notchHotkeyConflict = !hotkey.register(settings.notchHotkey, for: .notchToggle)
    }

    /// The legacy `NotchHighlightWindowController` overlay and the notch
    /// panel's own live-activity glow both exist to say "icons are clipped
    /// behind the notch" — showing both at once would double up over the
    /// same physical notch. When the notch panel is enabled, the overflow
    /// warning rides as a `LiveActivity` in its wings instead (posted by
    /// `notchActivityRouter`, which reacts to `notchEnabled` on its own); the
    /// legacy floating overlay is only (re)created when the notch panel is
    /// off. This method now only owns that overlay's lifecycle — the
    /// live-activity side of this coexistence moved to `NotchActivityRouter`
    /// (see its doc comment for why).
    private func configureNotchOverflowCoexistence() {
        if settings.notchEnabled {
            notchHighlight = nil
        } else if notchHighlight == nil {
            notchHighlight = NotchHighlightWindowController(
                arranger: arranger,
                onActivate: { [arranger] in arranger.setArranging(true) }
            )
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
