import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let arranger = MenuBarArranger()
    private let menuBarIcons = MenuBarIconManager()
    private let updater = UpdateChecker()
    private let crashReporter = CrashReporter()
    private var menuBar: MenuBarManager?
    private let hotkey = HotkeyManager()
    private var updateScheduler: AutomaticUpdateScheduler?

    private let notchWindow = NotchWindowController()
    private let nowPlayingService = NowPlayingService()
    private lazy var nowPlayingWidget = NowPlayingWidget(
        service: nowPlayingService, isEnabled: settings.notchNowPlayingEnabled)
    private let shelfStore = ShelfStore(deferLoad: true)
    private lazy var shelfWidget = ShelfWidget(
        store: shelfStore, isEnabled: settings.notchShelfEnabled)
    private let permissionCenter = PermissionCenter()
    private let calendarService = CalendarService()
    private lazy var calendarWidget = CalendarWidget(
        service: calendarService, permissions: permissionCenter, isEnabled: settings.notchCalendarEnabled)
    private let cameraService = CameraService()
    private lazy var mirrorWidget = MirrorWidget(
        service: cameraService, permissions: permissionCenter, isEnabled: settings.notchMirrorEnabled)
    private let clipboardMonitor = ClipboardMonitor()
    private lazy var clipboardWidget = ClipboardWidget(
        monitor: clipboardMonitor, isEnabled: settings.notchClipboardEnabled)
    private let timerService = TimerService()
    /// Built on first enable rather than at launch: a disabled lock-screen
    /// experiment must not pay for its geometry cache read, its appearance
    /// subscription or its distributed observers. See
    /// `configureLockScreenPresenter`.
    private var lockScreenPresenter: LockScreenPresenter?
    private var notchActivityRouter: NotchActivityRouter?

    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, arranger: arranger, iconManager: menuBarIcons, updater: updater,
        nowPlaying: nowPlayingService, permissions: permissionCenter,
        crashReporter: crashReporter, clipboardMonitor: clipboardMonitor)
    private var notchHighlight: NotchHighlightWindowController?

    private var cancellables = Set<AnyCancellable>()
    private let duoCalendarBoundaryTask = DeadlineTask()
    private var isReconcilingLaunchAtLogin = false
    private var hasStartedApplication = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let otherInstances = runningFluxInstances()
        if otherInstances.contains(where: shouldYieldToRunningInstance) {
            NSApp.terminate(nil)
            return
        }
        otherInstances.forEach { $0.terminate() }

        let start = { [weak self] in self?.startApplication() }
        if otherInstances.isEmpty {
            start()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { start() }
        }
    }

    private func runningFluxInstances() -> [NSRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != pid }
    }

    private func shouldYieldToRunningInstance(_ application: NSRunningApplication) -> Bool {
        guard let bundleURL = application.bundleURL,
              let version = Bundle(url: bundleURL)?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return false
        }
        return updater.isNewer(version, than: AppInfo.version)
    }

    private func startApplication() {
        guard !hasStartedApplication else { return }
        hasStartedApplication = true
        Log.menuBar.info("Flux launching")

        crashReporter.beginSession()

        menuBar = MenuBarManager(settings: settings, arranger: arranger,
                                 timerService: timerService) { [weak self] in
            self?.openSettings()
        }
        menuBar?.canHideWithoutAccess = { [weak self] in
            self?.menuBarIcons.canHideWithoutAccess ?? false
        }
        menuBarIcons.boundaryProvider = { [weak self] in
            guard let menuBar = self?.menuBar else { return (hidden: nil, alwaysHidden: nil) }
            let boundaries = menuBar.drawerBoundaries
            return (hidden: ControlItem.usesMacOS27Model
                        ? menuBar.chevronBoundary : boundaries.hidden,
                    alwaysHidden: boundaries.alwaysHidden)
        }
        menuBarIcons.chevronBoundaryProvider = { [weak self] in
            self?.menuBar?.chevronBoundary
        }
        menuBarIcons.alwaysHiddenEnabledProvider = { [weak self] in
            self?.settings.showAlwaysHiddenSection ?? false
        }
        menuBarIcons.beginProvider = { [weak self] in self?.menuBar?.beginIconManagement() }
        menuBarIcons.endProvider = { [weak self] in self?.menuBar?.endIconManagement() }
        menuBar?.onDrawerStateChanged = { [weak self] revealHidden, revealAlwaysHidden in
            self?.menuBarIcons.applyDrawerVisibility(
                revealHidden: revealHidden,
                revealAlwaysHidden: revealAlwaysHidden)
        }
        menuBar?.notifyDrawerState()
        menuBar?.pendingUpdateVersion = { [weak self] in self?.updater.pendingRelease?.version }
        menuBar?.onOpenSettingsTab = { [weak self] tab in self?.settingsWindow.show(tab: tab) }

        settings.launchAtLogin = LoginItemManager.setEnabled(settings.launchAtLogin)

        notchWindow.registry.register(nowPlayingWidget)
        notchWindow.registry.register(shelfWidget)
        notchWindow.registry.register(calendarWidget)
        notchWindow.registry.register(mirrorWidget)
        notchWindow.registry.register(clipboardWidget)
        notchWindow.artworkProvider = { [weak self] in self?.nowPlayingService.artwork }
        notchWindow.onShelfDrop = { [weak self] urls in
            guard let outcome = self?.shelfStore.add(urls: urls) else { return .declined }
            return .init(accepted: outcome.accepted, ready: outcome.added.count)
        }
        notchWindow.onActivityTap = { [weak self] kind in
            guard kind == .menuBarOverflow else { return false }
            self?.settingsWindow.show(tab: .menuBar)
            return true
        }
        notchWindow.menuProvider = { [weak self] in self?.menuBar?.makeMenu() ?? NSMenu() }

        NSApp.mainMenu = Self.makeMainMenu()

        configureHotkey()
        configureNotch()
        configureUpdateChecks()
        observeSettings()
        observeDuoCalendar()
        observeCrashBreadcrumbs()
        UpdateStartup.confirmLaunch()
    }

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

    static func describe(_ state: NotchState) -> String {
        switch state {
        case .collapsed: return "collapsed"
        case .activity: return "activity"
        case .expanded(let id): return "expanded(\(id.rawValue))"
        }
    }


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
                guard let self, !self.isReconcilingLaunchAtLogin else { return }
                let actual = LoginItemManager.setEnabled(enabled)
                guard actual != enabled else { return }
                // `@Published` emits from `willSet`, so this sink runs BEFORE
                // the triggering assignment has written its own storage. A
                // synchronous correction here completes first and is then
                // overwritten by that original write — leaving the toggle
                // showing precisely the state macOS refused, i.e. the bug
                // this was meant to fix, still there. (The same `willSet`
                // footgun `configureNotch` documents, pointing the other
                // way.)
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

        settings.$hotkeyShortcut
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureHotkey() }
            .store(in: &cancellables)

        settingsWindow.onVisibilityChanged = { [weak self] visible in
            self?.crashReporter.update { $0.settingsOpen = visible }
        }

        observeNotchSettings()
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


    /// `@Published` delivers to subscribers from `willSet`, BEFORE its own
    /// backing storage updates. `settings.$notchEnabled`'s sink calls this
    /// function, which then re-read `settings.notchEnabled` synchronously and
    /// saw the value from *before* the change. Turning the notch off left the
    /// panel, its monitors, the clipboard monitor and the lock-screen
    /// presenter all running until the next launch, even though the
    /// preference itself displayed and persisted as off.
    private func configureNotch(notchEnabled: Bool? = nil) {
        let notchOn = notchEnabled ?? settings.notchEnabled
        NSApp.appearance = settings.appearance.nsAppearance
        notchWindow.setShowInFullscreen(settings.notchShowInFullscreen)
        notchWindow.setAppearance(settings.appearance)
        notchWindow.setEnabled(notchOn)
        notchWindow.viewModel.expansionTrigger = settings.notchExpansionTrigger
        notchWindow.viewModel.hoverCloseDelay = settings.notchHoverCloseDelay
        notchWindow.registry.order = settings.notchWidgetOrder.compactMap(WidgetID.init(rawValue:))
        notchWindow.registry.setEnabled(.nowPlaying, settings.notchNowPlayingEnabled)
        notchWindow.registry.setEnabled(.shelf, settings.notchShelfEnabled)
        notchWindow.registry.setEnabled(.calendar, settings.notchCalendarEnabled)
        notchWindow.registry.setEnabled(.mirror, settings.notchMirrorEnabled)
        notchWindow.registry.setEnabled(.clipboard, settings.notchClipboardEnabled)
        applyShelfExpiry(notchEnabled: notchOn)
        configureNotchOverflowCoexistence(notchEnabled: notchOn)
        configureNotchHotkey(notchEnabled: notchOn)
        configureClipboardMonitor(notchEnabled: notchOn)
        configureLockScreenPresenter(notchEnabled: notchOn)
        recomputeDuoActive()
        // Construct the activity router only once the notch is actually on —
        // its init builds the power/Bluetooth/volume/media-key monitors and
        // wires their subscriptions. A disabled notch must not force any of
        // that; the `$notchEnabled` sink calls `configureNotch` again on
        // enable, which builds the router then.
        if notchOn, notchActivityRouter == nil {
            notchActivityRouter = NotchActivityRouter(
                activities: notchWindow.activities, settings: settings, arranger: arranger,
                calendar: calendarService, permissions: permissionCenter, viewModel: notchWindow.viewModel,
                timers: timerService,
                presentation: notchWindow.$isPresenting.eraseToAnyPublisher())
        }
    }

    /// Expiry is configured only while notch+shelf are on, so a disabled shelf
    /// never reads the manifest. Assigning a non-nil interval loads and sweeps.
    private func applyShelfExpiry(notchEnabled: Bool? = nil, shelfEnabled: Bool? = nil) {
        let active = (notchEnabled ?? settings.notchEnabled) && (shelfEnabled ?? settings.notchShelfEnabled)
        if active { shelfStore.expiryInterval = settings.notchShelfExpiryInterval }
    }

    private func configureClipboardMonitor(notchEnabled: Bool? = nil) {
        clipboardMonitor.setPersistenceEnabled(settings.notchClipboardPersistenceEnabled)
        if (notchEnabled ?? settings.notchEnabled) && settings.notchClipboardEnabled {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

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
        let enabled = (notchEnabled ?? settings.notchEnabled) && experimentEnabled
        if enabled, lockScreenPresenter == nil {
            lockScreenPresenter = LockScreenPresenter(
                nowPlaying: nowPlayingService, activities: notchWindow.activities, settings: settings)
        }
        // Tear a live presenter down when the experiment is switched off, but
        // never construct one just to tell it `false`.
        lockScreenPresenter?.setEnabled(enabled)
    }

    private func observeDuoCalendar() {
        calendarService.$upcoming
            .sink { [weak self] events in
                self?.recomputeDuoActive(calendarEvents: events)
            }
            .store(in: &cancellables)
    }

    /// `duoSettingEnabled`/`calendarPermissionGranted`/`calendarEvents` are optionals,
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
    private func recomputeDuoActive(duoSettingEnabled: Bool? = nil,
                                    calendarPermissionGranted: Bool? = nil,
                                    calendarEvents: [CalendarEvent]? = nil) {
        let events = calendarEvents ?? calendarService.upcoming
        let now = Date()
        let calendarEnabled = notchWindow.registry.enabledWidgets.contains { $0.id == .calendar }
        notchWindow.viewModel.duoActive = NotchViewModel.duoActive(
            duoSettingEnabled: duoSettingEnabled ?? settings.notchDuoEnabled,
            calendarWidgetEnabled: calendarEnabled,
            calendarPermissionGranted: calendarPermissionGranted ?? (permissionCenter.statuses[.calendar] == .granted),
            calendarHasRelevantEvents: CalendarService.hasDuoEvents(events: events, now: now))

        let duoConfigured = (duoSettingEnabled ?? settings.notchDuoEnabled) && calendarEnabled
        if duoConfigured {
            duoCalendarBoundaryTask.reschedule(
                to: CalendarService.nextDuoVisibilityBoundary(events: events, now: now),
                action: { [weak self] in self?.recomputeDuoActive() })
        } else {
            duoCalendarBoundaryTask.cancel()
        }
    }

    private func observeNotchSettings() {
        settings.$notchEnabled
            .dropFirst()
            .sink { [weak self] enabled in self?.configureNotch(notchEnabled: enabled) }
            .store(in: &cancellables)

        settings.$notchExpansionTrigger
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.viewModel.expansionTrigger = value }
            .store(in: &cancellables)

        settings.$notchHoverCloseDelay
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.viewModel.hoverCloseDelay = value }
            .store(in: &cancellables)

        settings.$notchShowInFullscreen
            .dropFirst()
            .sink { [weak self] value in self?.notchWindow.setShowInFullscreen(value) }
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
            .sink { [weak self] value in
                self?.notchWindow.registry.setEnabled(.shelf, value)
                self?.applyShelfExpiry(shelfEnabled: value)
            }
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

        settings.$notchClipboardEnabled
            .dropFirst()
            .sink { [weak self] value in
                self?.notchWindow.registry.setEnabled(.clipboard, value)
                self?.configureClipboardMonitor()
            }
            .store(in: &cancellables)

        settings.$notchClipboardPersistenceEnabled
            .dropFirst()
            .sink { [weak self] value in
                self?.clipboardMonitor.setPersistenceEnabled(value)
            }
            .store(in: &cancellables)

        settings.$notchLockScreenExperimentEnabled
            .dropFirst()
            .sink { [weak self] value in self?.configureLockScreenPresenter(lockScreenExperimentEnabled: value) }
            .store(in: &cancellables)

        settings.$notchShelfExpiryDays
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyShelfExpiry()
            }
            .store(in: &cancellables)

        settings.$notchHotkey
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configureNotchHotkey() }
            .store(in: &cancellables)
    }

    private func configureNotchHotkey(notchEnabled: Bool? = nil) {
        hotkey.onTrigger[.notchToggle] = { [weak self] in self?.notchWindow.hotkeyToggled() }
        guard (notchEnabled ?? settings.notchEnabled), settings.notchHotkey.isValid else {
            hotkey.unregister(.notchToggle)
            settings.notchHotkeyConflict = false
            return
        }
        settings.notchHotkeyConflict = !hotkey.register(settings.notchHotkey, for: .notchToggle)
    }

    private func configureNotchOverflowCoexistence(notchEnabled: Bool? = nil) {
        if notchEnabled ?? settings.notchEnabled {
            notchHighlight = nil
        } else if notchHighlight == nil {
            notchHighlight = NotchHighlightWindowController(
                arranger: arranger,
                onActivate: { [weak self] in self?.settingsWindow.show(tab: .menuBar) }
            )
        }
    }


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
        NSApp.windowsMenu = windowMenu

        return main
    }


    private func configureUpdateChecks() {
        updateScheduler = AutomaticUpdateScheduler(
            enabled: settings.$automaticUpdateChecks.eraseToAnyPublisher()
        ) { [weak self] in
            self?.updater.checkForUpdates(userInitiated: false)
        }
    }


    func openSettings() {
        settingsWindow.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }
}
