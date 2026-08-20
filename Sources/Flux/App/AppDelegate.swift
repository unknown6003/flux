import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let arranger = MenuBarArranger()
    private let updater = UpdateChecker()
    /// Notices that the last run died without a clean shutdown, and remembers
    /// what the notch/camera were doing at the time — see `CrashReporter`'s
    /// own doc comment on why a hardware-only crash needs this.
    private let crashReporter = CrashReporter()
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
    // M6 (Camera) reuses the same instance.
    private let permissionCenter = PermissionCenter()
    // EventKit is owned here, shared between `calendarWidget` (the agenda
    // UI, read-only) and `notchActivityRouter` (the event-soon live
    // activity, and the SOLE caller of `start()`/`stop()` — see
    // `CalendarService`'s own doc comment on that ownership fix).
    private let calendarService = CalendarService()
    private lazy var calendarWidget = CalendarWidget(
        service: calendarService, permissions: permissionCenter, isEnabled: settings.notchCalendarEnabled)
    // M6: Mirror owns `CameraService.start()`/`stop()` itself (see that
    // widget's own doc comment on why its lifecycle needs no shared router
    // the way Calendar's does) — `permissionCenter` above is reused rather
    // than a second instance.
    private let cameraService = CameraService()
    private lazy var mirrorWidget = MirrorWidget(
        service: cameraService, permissions: permissionCenter, isEnabled: settings.notchMirrorEnabled)
    // M6: `ClipboardMonitor.start()`/`stop()` is settings-driven (see its own
    // doc comment) rather than tied to `ClipboardWidget`'s presentation — the
    // whole point of a history is that it keeps accumulating while the
    // widget itself is closed. Wired from `configureClipboardMonitor()` below.
    private let clipboardMonitor = ClipboardMonitor()
    private lazy var clipboardWidget = ClipboardWidget(
        monitor: clipboardMonitor, isEnabled: settings.notchClipboardEnabled)
    // M6: `TimerService` has no start/stop lifecycle at all (a single
    // cancellable boundary `Task`, rearmed on mutation — see its own doc
    // comment), so unlike every other notch-suite service there's nothing
    // for either `TimersWidget` or `notchActivityRouter` to start/stop here;
    // both just consume this one shared instance.
    private let timerService = TimerService()
    private lazy var timersWidget = TimersWidget(
        service: timerService, isEnabled: settings.notchTimersEnabled)
    // M6/M9: EXPERIMENTAL — see `LockScreenPresenter`'s own doc comment.
    // Gated from `configureLockScreenPresenter()` below. `lazy` (like the
    // widgets above) because its initializer reads sibling instance
    // properties (`nowPlayingService`, `notchWindow.activities`, `settings`),
    // which isn't possible from a plain stored property's default-value
    // expression; forced into existence by `configureLockScreenPresenter()`'s
    // own `lockScreenPresenter.setEnabled(...)` call, so nothing extra is
    // needed to touch it the way `notchActivityRouter` needs its explicit
    // `_ = notchActivityRouter` line.
    private lazy var lockScreenPresenter = LockScreenPresenter(
        nowPlaying: nowPlayingService, activities: notchWindow.activities, settings: settings)
    // Single home for every live-activity *producer* (menu-bar overflow,
    // battery, Bluetooth, calendar, volume HUD) — see
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
        timers: timerService,
        presentation: notchWindow.$isPresenting.eraseToAnyPublisher())

    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, arranger: arranger, updater: updater,
        nowPlaying: nowPlayingService, permissions: permissionCenter,
        crashReporter: crashReporter)
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
    /// See the `$launchAtLogin` sink — guards its own write-back from
    /// re-entering it.
    private var isReconcilingLaunchAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.menuBar.info("Flux launching")

        // First thing: reading the previous session has to happen before
        // anything this launch does can overwrite it.
        crashReporter.beginSession()

        menuBar = MenuBarManager(settings: settings, arranger: arranger) { [weak self] in
            self?.openSettings()
        }
        // Lets a background-found update surface somewhere the user actually
        // looks — see `MenuBarManager.pendingUpdateVersion`.
        menuBar?.pendingUpdateVersion = { [weak self] in self?.updater.pendingRelease?.version }
        menuBar?.onOpenSettingsTab = { [weak self] tab in self?.settingsWindow.show(tab: tab) }

        // Reconcile the login-item registration with the saved preference. The OS
        // is the source of truth, so push the actual state back into settings.
        settings.launchAtLogin = LoginItemManager.setEnabled(settings.launchAtLogin)

        notchWindow.registry.register(nowPlayingWidget)
        notchWindow.registry.register(shelfWidget)
        notchWindow.registry.register(calendarWidget)
        notchWindow.registry.register(mirrorWidget)
        notchWindow.registry.register(timersWidget)
        notchWindow.registry.register(clipboardWidget)
        notchWindow.artworkProvider = { [weak self] in self?.nowPlayingService.artwork }
        // A file dropped on the *collapsed* notch is caught at the window
        // level (see `NotchPanel`/`NotchWindowController`), which has no
        // knowledge of `ShelfStore` itself — this is the one place that
        // knowledge gap is bridged.
        // Both counts are forwarded — see `NotchWindowController.ShelfDropResult`
        // for why the drag's success and the confirmation wing's wording must
        // come from different numbers.
        notchWindow.onShelfDrop = { [weak self] urls in
            guard let outcome = self?.shelfStore.add(urls: urls) else { return .declined }
            return .init(accepted: outcome.accepted, ready: outcome.added.count)
        }
        // A tap on the overflow indicator's wings should open Arrange Mode,
        // same as the legacy `NotchHighlightWindowController` glow's
        // `onActivate` — not toggle the notch panel itself, which is what a
        // plain `viewModel.clicked()` would otherwise do for every activity.
        notchWindow.onActivityTap = { [arranger] kind in
            guard kind == .menuBarOverflow else { return false }
            arranger.setArranging(true)
            return true
        }
        // Right-clicking the notch should feel like right-clicking the
        // chevron does — same kind of menu, in the other place Flux draws
        // itself. `NotchWindowController` decides *when* a right-click counts
        // as on the notch; this closure is the only thing that knows what
        // should be *in* the menu.
        notchWindow.menuProvider = { [weak self] in self?.makeNotchMenu() ?? NSMenu() }
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

        NSApp.mainMenu = Self.makeMainMenu()

        configureHotkey()
        configureNotch()
        configureUpdateChecks()
        observeSettings()
        observeCrashBreadcrumbs()
    }

    /// Flipping the session file to "clean" is the entire crash-detection
    /// mechanism: a crash never reaches this method, so finding the flag
    /// still false at the next launch is what identifies an abnormal exit.
    func applicationWillTerminate(_ notification: Notification) {
        crashReporter.endSession()
    }

    /// Keeps `CrashReporter`'s breadcrumb tracking the two things most likely
    /// to matter in a crash report — what the notch was showing, and whether
    /// the capture session was live — plus the current live activity. All of
    /// it is Flux's own UI state; see `CrashReporter`'s privacy note on why
    /// nothing user-derived may be added here.
    private func observeCrashBreadcrumbs() {
        notchWindow.viewModel.$state
            .sink { [weak self] state in
                self?.crashReporter.update { $0.notchState = Self.describe(state) }
            }
            .store(in: &cancellables)

        cameraService.$isRunning
            .sink { [weak self] running in
                self?.crashReporter.update { $0.cameraRunning = running }
            }
            .store(in: &cancellables)

        notchWindow.activities.$current
            .sink { [weak self] activity in
                self?.crashReporter.update { $0.activityKind = activity.map { "\($0.kind)" } }
            }
            .store(in: &cancellables)
    }

    /// `NotchState` as a stable string. Deliberately not `String(describing:)`
    /// on the whole value — `.activity` carries a `UUID` that would churn the
    /// breadcrumb (and the file write behind it) on every activity change
    /// while saying nothing useful.
    static func describe(_ state: NotchState) -> String {
        switch state {
        case .collapsed: return "collapsed"
        case .activity: return "activity"
        case .expanded(let id): return "expanded(\(id.rawValue))"
        }
    }

    // MARK: Settings reactions

    private func observeSettings() {
        settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] enabled in
                // `setEnabled` swallows the throw and hands back the state
                // that ACTUALLY resulted — registration legitimately fails
                // when the user hasn't approved Flux under System Settings ›
                // General › Login Items. Discarding that (as this used to)
                // left the switch showing "on" for something macOS refused,
                // so Flux quietly didn't launch at login and nothing said so.
                // Launch already reconciles this way; a live toggle now does
                // too. The inequality guard is load-bearing: writing the same
                // value back would re-enter this sink through the property's
                // own `didSet`.
                guard let self, !self.isReconcilingLaunchAtLogin else { return }
                let actual = LoginItemManager.setEnabled(enabled)
                guard actual != enabled else { return }
                // DEFERRED one runloop turn, and that is the whole fix.
                // `@Published` emits from `willSet`, so this sink runs BEFORE
                // the triggering assignment has written its own storage. A
                // synchronous correction here completes first and is then
                // overwritten by that original write — leaving the toggle
                // showing precisely the state macOS refused, i.e. the bug
                // this was meant to fix, still there. (The same `willSet`
                // footgun `configureNotch` documents, pointing the other
                // way.)
                //
                // The flag still earns its keep: the deferred write re-enters
                // this sink, and without it that re-entry would call
                // `LoginItemManager.setEnabled` a second time for the same
                // failure.
                self.isReconcilingLaunchAtLogin = true
                DispatchQueue.main.async {
                    self.settings.launchAtLogin = actual
                    self.isReconcilingLaunchAtLogin = false
                }
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
            self?.crashReporter.update { $0.settingsOpen = visible }
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
    /// `notchEnabled` follows the same emitted-value convention as
    /// `recomputeDuoActive`/`configureLockScreenPresenter` below, and for the
    /// same reason — but this one was missing it, which made the master notch
    /// toggle itself unreliable.
    ///
    /// `@Published` delivers to subscribers from `willSet`, BEFORE its own
    /// backing storage updates. `settings.$notchEnabled`'s sink calls this
    /// function, which then re-read `settings.notchEnabled` synchronously and
    /// saw the value from *before* the change. Turning the notch off left the
    /// panel, its monitors, the clipboard monitor and the lock-screen
    /// presenter all running until the next launch, even though the
    /// preference itself displayed and persisted as off.
    private func configureNotch(notchEnabled: Bool? = nil) {
        let notchOn = notchEnabled ?? settings.notchEnabled
        // Give transient Flux-owned overlays (Arrange Mode and overflow
        // hints) the same appearance as the persistent Settings/notch windows.
        NSApp.appearance = settings.appearance.nsAppearance
        // Applied before `setEnabled` so a fresh panel is built with the
        // right collection behavior from the start, rather than defaulting
        // to `NotchPanel.init`'s always-on `.fullScreenAuxiliary` for one
        // tick and then immediately being corrected.
        notchWindow.setShowInFullscreen(settings.notchShowInFullscreen)
        notchWindow.setStyle(settings.notchStyle)
        notchWindow.setAppearance(settings.appearance)
        notchWindow.setEnabled(notchOn)
        notchWindow.viewModel.expansionTrigger = settings.notchExpansionTrigger
        notchWindow.viewModel.hoverOpenDelay = settings.notchHoverOpenDelay
        notchWindow.viewModel.hoverCloseDelay = settings.notchHoverCloseDelay
        notchWindow.registry.order = settings.notchWidgetOrder.compactMap(WidgetID.init(rawValue:))
        notchWindow.registry.setEnabled(.nowPlaying, settings.notchNowPlayingEnabled)
        notchWindow.registry.setEnabled(.shelf, settings.notchShelfEnabled)
        notchWindow.registry.setEnabled(.calendar, settings.notchCalendarEnabled)
        notchWindow.registry.setEnabled(.mirror, settings.notchMirrorEnabled)
        notchWindow.registry.setEnabled(.timers, settings.notchTimersEnabled)
        notchWindow.registry.setEnabled(.clipboard, settings.notchClipboardEnabled)
        shelfStore.expiryInterval = settings.notchShelfExpiryInterval
        configureNotchOverflowCoexistence(notchEnabled: notchOn)
        configureNotchHotkey(notchEnabled: notchOn)
        configureClipboardMonitor(notchEnabled: notchOn)
        configureLockScreenPresenter(notchEnabled: notchOn)
        recomputeDuoActive()
        // Force the lazy router into existence — see its property doc
        // comment for why nothing else naturally touches it. Its own `init`
        // reads the live activity toggles directly, so no further settings
        // plumbing is needed here.
        _ = notchActivityRouter
    }

    /// Clipboard history collection follows both its OWN toggle and the
    /// master notch switch — a disabled notch feature means "off" everywhere,
    /// including a background monitor with nothing to actually show its
    /// history in (see `ClipboardMonitor`'s own doc comment on why its
    /// lifecycle is settings-, not presentation-, driven).
    private func configureClipboardMonitor(notchEnabled: Bool? = nil) {
        if (notchEnabled ?? settings.notchEnabled) && settings.notchClipboardEnabled {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

    /// EXPERIMENTAL — same "both this feature's own toggle AND the master
    /// notch switch" gating as `configureClipboardMonitor`, for the same
    /// reason: a disabled notch feature means off everywhere.
    ///
    /// `lockScreenExperimentEnabled` — like `recomputeDuoActive`'s own
    /// optional params (see that function's doc comment) — takes the value a
    /// `settings.$notchLockScreenExperimentEnabled` sink was just handed
    /// rather than defaulting to a re-read of `settings.
    /// notchLockScreenExperimentEnabled`: `@Published` delivers via `willSet`,
    /// so a sink that re-reads the stored property instead of using its own
    /// emitted value would see the OLD one, one toggle behind. Falls back to
    /// a live read when called with no argument (every other call site here —
    /// startup, and any other setting's sink recomputing this incidentally —
    /// has no fresher value to hand it).
    private func configureLockScreenPresenter(lockScreenExperimentEnabled: Bool? = nil,
                                              notchEnabled: Bool? = nil) {
        let experimentEnabled = lockScreenExperimentEnabled ?? settings.notchLockScreenExperimentEnabled
        lockScreenPresenter.setEnabled((notchEnabled ?? settings.notchEnabled) && experimentEnabled)
    }

    /// M7 (Alcove parity): pushes the pure `NotchViewModel.duoActive(...)`
    /// derivation into the live view model — called from every input that
    /// could change its answer: the Duo setting itself, the Calendar
    /// widget's own enabled state (`settings.$notchCalendarEnabled`'s sink,
    /// below), and Calendar permission (`permissionCenter.$statuses`'s sink,
    /// below), plus once here at launch. Kept as this one small function
    /// (rather than inlined into each sink) so every trigger stays in sync
    /// with the same read of `notchWindow.registry`/`permissionCenter`.
    ///
    /// `duoSettingEnabled`/`calendarPermissionGranted` are optionals,
    /// defaulting to `nil` (read live from `settings`/`permissionCenter`) —
    /// callers reacting to a settings/permission change THAT ISN'T
    /// `notchDuoEnabled`/`permissionCenter.statuses` itself (e.g.
    /// `notchCalendarEnabled`'s own sink) pass nothing and get the live read.
    /// But `settings.$notchDuoEnabled`'s own sink and
    /// `permissionCenter.$statuses`'s own sink (below) MUST pass the value
    /// they were just handed instead: `@Published` delivers to subscribers
    /// from `willSet`, before its own backing storage is actually updated, so
    /// a synchronous re-read of `settings.notchDuoEnabled`/
    /// `permissionCenter.statuses` from inside one of those two sinks would
    /// see the STALE pre-change value — the exact bug class M6's
    /// `recomputeTimerActivity(timers:)` fix addressed for `timers.$timers`.
    private func recomputeDuoActive(duoSettingEnabled: Bool? = nil, calendarPermissionGranted: Bool? = nil) {
        notchWindow.viewModel.duoActive = NotchViewModel.duoActive(
            duoSettingEnabled: duoSettingEnabled ?? settings.notchDuoEnabled,
            calendarWidgetEnabled: notchWindow.registry.enabledWidgets.contains { $0.id == .calendar },
            calendarPermissionGranted: calendarPermissionGranted ?? (permissionCenter.statuses[.calendar] == .granted))
    }

    private func observeNotchSettings() {
        settings.$notchEnabled
            .dropFirst()
            // The emitted value, NOT a re-read — see `configureNotch`'s doc
            // comment. This is the repo's recurring Combine footgun.
            .sink { [weak self] enabled in self?.configureNotch(notchEnabled: enabled) }
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

        settings.$notchStyle
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.setStyle(value) }
            .store(in: &cancellables)

        settings.$appearance
            .dropFirst()
            .sink { [weak self] value in
                NSApp.appearance = value.nsAppearance
                self?.notchWindow.setAppearance(value)
            }
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
            .sink { [weak self] value in
                self?.notchWindow.registry.setEnabled(.calendar, value)
                self?.recomputeDuoActive()
            }
            .store(in: &cancellables)

        settings.$notchDuoEnabled
            .dropFirst()
            .sink { [weak self] value in self?.recomputeDuoActive(duoSettingEnabled: value) }
            .store(in: &cancellables)

        // Calendar permission can change independently of every settings
        // toggle above (granted/revoked in System Settings) — Duo view must
        // drop out the moment access is revoked, not just the next time some
        // other setting happens to change.
        permissionCenter.$statuses
            .dropFirst()
            .sink { [weak self] statuses in
                self?.recomputeDuoActive(calendarPermissionGranted: statuses[.calendar] == .granted)
            }
            .store(in: &cancellables)

        settings.$notchMirrorEnabled
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.registry.setEnabled(.mirror, value) }
            .store(in: &cancellables)

        settings.$notchTimersEnabled
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.registry.setEnabled(.timers, value) }
            .store(in: &cancellables)

        settings.$notchClipboardEnabled
            .dropFirst()
            .sink { [weak self] value in
                self?.notchWindow.registry.setEnabled(.clipboard, value)
                self?.configureClipboardMonitor()
            }
            .store(in: &cancellables)

        settings.$notchLockScreenExperimentEnabled
            .dropFirst()
            .sink { [weak self] value in self?.configureLockScreenPresenter(lockScreenExperimentEnabled: value) }
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
    private func configureNotchHotkey(notchEnabled: Bool? = nil) {
        // Routed through `NotchWindowController.hotkeyToggled()` (not the
        // view model directly) so it's a no-op while the controller has
        // nothing presenting — the hotkey stays registered even on an
        // external-only clamshell setup with no built-in notched screen,
        // and must not drive a headless expand in that case.
        hotkey.onTrigger[.notchToggle] = { [weak self] in self?.notchWindow.hotkeyToggled() }
        guard (notchEnabled ?? settings.notchEnabled), settings.notchHotkey.isValid else {
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
    private func configureNotchOverflowCoexistence(notchEnabled: Bool? = nil) {
        if notchEnabled ?? settings.notchEnabled {
            notchHighlight = nil
        } else if notchHighlight == nil {
            notchHighlight = NotchHighlightWindowController(
                arranger: arranger,
                onActivate: { [arranger] in arranger.setArranging(true) }
            )
        }
    }

    // MARK: Main menu

    /// The app menu bar, used only while Flux is temporarily `.regular` —
    /// i.e. while the Settings window is open (see
    /// `SettingsWindowController.applyRegularActivationPolicy`).
    ///
    /// An `LSUIElement` app has no menu bar and needs none. But promoting to
    /// `.regular` without setting `NSApp.mainMenu` gives you the *worst* of
    /// both: a visible, empty menu bar, and no ⌘W to close the window, no ⌘Q
    /// to quit, and no ⌘X/⌘C/⌘V inside the hotkey recorder or any text field
    /// — because those standard shortcuts are menu items, not built-in
    /// behaviour. This is the minimum that makes the promoted state feel like
    /// a real app rather than a broken one.
    ///
    /// Every item uses a nil target, so AppKit routes it through the
    /// responder chain to whatever is actually focused. That's what makes the
    /// Edit items work in a text field without this class knowing anything
    /// about them.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppInfo.name)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        // Hands AppKit the Window menu it manages itself (window list,
        // Bring All to Front) rather than leaving it a static three items.
        NSApp.windowsMenu = windowMenu

        return main
    }

    // MARK: Notch context menu

    /// Built fresh on every right-click (not cached) so every dynamic part —
    /// the expand/collapse verb, the widget checkmarks — reflects the state
    /// at the moment the menu opens rather than whenever it was last built.
    private func makeNotchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Same signpost the chevron's menu carries — see
        // `MenuBarManager.pendingUpdateVersion`.
        if let version = updater.pendingRelease?.version {
            // `.general`, not the generic open — the install controls are
            // there, and `show()` alone would preserve whatever tab the user
            // last had open (Codex PR13 finding).
            let item = makeNotchItem("Update to \(version)…", #selector(notchMenuOpenUpdateSettings))
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let isExpanded: Bool
        if case .expanded = notchWindow.viewModel.state { isExpanded = true } else { isExpanded = false }
        menu.addItem(makeNotchItem(isExpanded ? "Collapse Notch" : "Expand Notch",
                                   #selector(notchMenuToggle)))

        menu.addItem(.separator())

        let widgets = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // Walks `WidgetID.allCases` rather than `registry.enabledWidgets` on
        // purpose: a *disabled* widget is exactly the one the user needs to
        // find here to switch back on, and it's absent from `enabledWidgets`
        // by definition.
        for id in WidgetID.allCases {
            let item = makeNotchItem(id.title, #selector(notchMenuToggleWidget))
            item.state = settings[keyPath: id.enabledSettingKey] ? .on : .off
            item.image = NSImage(systemSymbolName: id.symbol, accessibilityDescription: nil)
            item.representedObject = id.rawValue
            submenu.addItem(item)
        }
        widgets.submenu = submenu
        menu.addItem(widgets)

        menu.addItem(.separator())
        menu.addItem(makeNotchItem("Notch Settings…", #selector(notchMenuOpenNotchSettings)))
        menu.addItem(makeNotchItem("Flux Settings…", #selector(notchMenuOpenSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeNotchItem("Turn Off Notch", #selector(notchMenuDisable)))
        menu.addItem(.separator())
        menu.addItem(makeNotchItem("Quit Flux", #selector(notchMenuQuit), key: "q"))
        return menu
    }

    /// `isEnabled` is set explicitly because `menu.autoenablesItems` is off —
    /// with automatic enabling on, AppKit validates against the responder
    /// chain, and a menu popped from a non-activating panel in an accessory
    /// app has no useful responder chain to validate against, so every item
    /// would come up greyed out.
    private func makeNotchItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func notchMenuToggle() { notchWindow.hotkeyToggled() }

    @objc private func notchMenuToggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = WidgetID(rawValue: raw) else { return }
        // Written through `settings` (not `registry.setEnabled` directly) so
        // the change persists and the Settings window's own toggle updates
        // with it — the registry is driven from the settings sink in
        // `observeNotchSettings()`.
        settings[keyPath: id.enabledSettingKey].toggle()
    }

    @objc private func notchMenuOpenNotchSettings() { settingsWindow.show(tab: .notch) }

    @objc private func notchMenuOpenUpdateSettings() { settingsWindow.show(tab: .general) }

    @objc private func notchMenuOpenSettings() { openSettings() }

    @objc private func notchMenuDisable() { settings.notchEnabled = false }

    @objc private func notchMenuQuit() { NSApp.terminate(nil) }

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
