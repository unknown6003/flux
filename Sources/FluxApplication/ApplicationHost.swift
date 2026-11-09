import AppKit
import FluxCore
import FluxPlatform
import FluxUI

/// The app delegate keeps one host. Required menu-bar and lock-screen owners
/// complete the composition; this type has no placeholder implementations.
@MainActor public final class ApplicationHost: SettingsEffects {
    private let session: any HostSession
    private let menuBar: any MenuBarService
    private let lockScreen: any LockScreenService
    private let bundle: Bundle
    private let failure: @MainActor (ApplicationFailure) -> Void
    private let quit: @MainActor () -> Void
    private var active = false
    private var crashDismissed = false
    private var phase: SessionPhase = .locked
    private var permissionTask: Task<Void, Never>?

    private lazy var settings: SettingsCoordinator = SettingsCoordinator(preferences: session.preferences,
        usage: session.usage, version: session.version, effects: self)
    private lazy var shortcuts: AppShortcuts = AppShortcuts(preferences: session.preferences,
        reveal: { [weak self] in self?.menuBar.toggle() }, notch: { [weak self] in self?.notch.toggle() })
    private lazy var updates: UpdateCoordinator = UpdateCoordinator(version: session.version.version,
        installURL: bundle.bundleURL, changed: { [weak self] in self?.settings.refresh() },
        readyToQuit: { [weak self] in self?.quit() },
        manualInstall: { [weak self] in self?.open($0) })
    private lazy var notch: NotchSubsystem = NotchSubsystem(preferences: session.preferences, files: session.files,
        mediaScript: bundle.bundleURL.appendingPathComponent("Contents/Resources/mediaremote-adapter.pl"),
        mediaFramework: bundle.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework"),
        callbacks: .init(report: { [weak self] in self?.failure(.runtime($0)) },
            contentChanged: { [weak self] in self?.lockScreen.receive($0) },
            phaseChanged: { [weak self] phase in
                self?.phase = phase
                self?.lockScreen.setPhase(phase)
            }, cameraRunning: { [weak self] in self?.session.cameraIsRunning($0) },
            accessChanged: { [weak self] in self?.settings.refresh() },
            timerCompleted: { _ in NSSound.beep() },
            activityChanged: { [weak self] in self?.lockScreen.updateActivity($0) },
            makeLockScreenService: { [unowned self] in try self.lockScreen.makeHandle() }))

    public convenience init(session: ApplicationSession, menuBar: any MenuBarService, lockScreen: any LockScreenService,
                bundle: Bundle = .main, failure: @escaping @MainActor (ApplicationFailure) -> Void,
                quit: @escaping @MainActor () -> Void) {
        self.init(owner: session, menuBar: menuBar, lockScreen: lockScreen, bundle: bundle,
                  failure: failure, quit: quit)
    }

    init(owner: any HostSession, menuBar: any MenuBarService, lockScreen: any LockScreenService,
         bundle: Bundle = .main, failure: @escaping @MainActor (ApplicationFailure) -> Void,
         quit: @escaping @MainActor () -> Void) {
        self.session = owner; self.menuBar = menuBar; self.lockScreen = lockScreen
        self.bundle = bundle; self.failure = failure; self.quit = quit
    }

    deinit { permissionTask?.cancel() }

    public func start() throws {
        guard !active else { return }
        active = true
        setAppearance()
        menuBar.onAction = { [weak self] in self?.handle($0) }
        menuBar.onChange = { [weak self] in self?.settings.refresh() }
        menuBar.onOverflow = { [weak self] in self?.notch.setOverflowCount($0) }
        lockScreen.onChange = { [weak self] in self?.settings.refresh() }
        lockScreen.onTransport = { [weak self] in self?.notch.sendLockScreenTransport($0) }
        shortcuts.start()
        notch.start()
        // A synchronous first menu-bar scan can now publish its overflow.
        menuBar.start()
        try session.markReady()
        updates.start(automatic: session.preferences.value(for: Preferences.automaticUpdateChecks))
    }

    /// Call from applicationShouldTerminate's asynchronous termination path.
    /// Private views and listeners stop before restoring the menu bar and
    /// writing the clean-session marker.
    public func stop() async {
        guard active else { return }
        active = false
        permissionTask?.cancel(); permissionTask = nil
        updates.stop(); shortcuts.stop(); settings.close()
        notch.stop(); lockScreen.stop()
        menuBar.onAction = nil; menuBar.onChange = nil; menuBar.onOverflow = nil
        lockScreen.onChange = nil
        lockScreen.onTransport = nil
        do { try await menuBar.stop() } catch { failure(.menuBarRecovery) }
        session.finish()
    }

    public func showSettings(_ page: SettingsPage? = nil) {
        guard active else { return }
        updates.clearStaleOutcome()
        session.usage.record(.opened(.settings))
        settings.show(page)
    }

    private func handle(_ action: MenuBarAction) {
        guard active else { return }
        switch action {
        case .toggle: menuBar.toggle()
        case .showAll: menuBar.showAll()
        case .organize: showSettings(.menuBar)
        case .openNotch: notch.toggle()
        case .settings: showSettings()
        case .quit: quit()
        case .startTimer(let minutes):
            do { try notch.startTimer(minutes: minutes) } catch { failure(.timer) }
        case .cancelTimers: notch.cancelAllTimers()
        }
    }

    // MARK: SettingsEffects

    public func settingsWillShow(_ page: SettingsPage) {
        if page == .menuBar { menuBar.setEditorVisible(true) }
    }
    public func settingsWillHide(_ page: SettingsPage) {
        if page == .menuBar { menuBar.setEditorVisible(false) }
    }
    public func loginStatus() -> LoginStatus {
        switch LoginItem.state {
        case .disabled: .disabled
        case .enabled: .enabled
        case .needsApproval: .requiresApproval
        case .unavailable: .unavailable
        }
    }
    public func shortcutConflict(_ role: ShortcutRole) -> ShortcutConflict { shortcuts.conflict(role) }
    public func updateStatus() -> UpdateStatus { updates.status }
    public func permissionRows() -> [PermissionRow] {
        SystemPermission.allCases.map { permission in
            let kind: PermissionKind = switch permission {
            case .accessibility: .accessibility
            case .screenRecording: .screenRecording
            case .calendar: .calendar
            case .camera: .camera
            case .bluetooth: .bluetooth
            }
            let status: PermissionStatus = switch PermissionAccess.status(permission) {
            case .allowed: .allowed
            case .notAsked: .notAsked
            case .notAllowed: .notAllowed
            case .unknown: .unknown
            }
            return PermissionRow(kind: kind, status: status)
        }
    }
    public func notchAccess(_ kind: NotchAccessKind) -> NotchAccessStatus {
        switch PermissionAccess.status(systemPermission(kind)) {
        case .allowed: .allowed
        case .notAsked: .notAsked
        case .notAllowed: .denied
        case .unknown: .unavailable
        }
    }
    public func lockScreenCapability() -> LockScreenCapability { lockScreen.capability }
    public func lockScreenFailureCode() -> String? { lockScreen.failureCode }
    public func crashNotice() -> CrashNotice {
        session.previousSessionWasUnclean && !crashDismissed
            ? .previousSessionUnclean(cameraWasRunning: session.previousCameraWasRunning) : .none
    }
    public func menuBarState() -> MenuBarPageState { menuBar.state }
    public func apply(_ change: SettingsChange) {
        guard active else { return }
        switch change {
        case .hotkeysEnabled: shortcuts.refresh()
        case .appearance: setAppearance()
        case .automaticUpdateChecks(let enabled): updates.setAutomatic(enabled)
        case .menuBarOptions: menuBar.configure()
        case .presentation, .features: notch.refresh(); lockScreen.configure()
        }
        settings.refresh()
    }
    public func report(_ failure: SettingsFailure) { self.failure(.settings(failure)) }
    public func setLoginItem(_ enabled: Bool) throws -> LoginStatus {
        _ = try LoginItem.setEnabled(enabled)
        return loginStatus()
    }
    public func openLoginItemsSettings() { LoginItem.openSettings() }
    public func replaceShortcut(_ role: ShortcutRole, with shortcut: Shortcut) -> Bool { shortcuts.replace(role, with: shortcut) }
    public func checkForUpdates() { updates.check() }
    public func installUpdate() { updates.install() }
    public func openPermissionSettings(_ kind: PermissionKind) {
        let permission: SystemPermission = switch kind {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .calendar: .calendar
        case .camera: .camera
        case .bluetooth: .bluetooth
        }
        PermissionAccess.openSettings(permission)
    }
    public func requestNotchAccess(_ kind: NotchAccessKind) {
        guard active, permissionTask == nil else { return }
        let permission = systemPermission(kind)
        permissionTask = Task { @MainActor [weak self] in
            let access = await PermissionAccess.request(permission)
            guard let self, self.active, !Task.isCancelled else { return }
            self.permissionTask = nil
            self.session.usage.record(.completed(.permissionRequest, access == .allowed ? .succeeded : .declined))
            self.notch.refresh()
            self.settings.refresh()
        }
    }
    public func openNotchAccessSettings(_ kind: NotchAccessKind) { PermissionAccess.openSettings(systemPermission(kind)) }
    public func setClipboardPersistence(_ enabled: Bool) async throws { try await notch.setClipboardPersistence(enabled) }
    public func clearClipboardHistory() async throws { try await notch.clearClipboardHistory() }
    public func openLockScreenSettings() {
        open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
    }
    public func checkLockScreenAgain() { lockScreen.checkAgain(); settings.refresh() }
    public func copyDiagnosticReport() -> Bool {
        let phase = switch self.phase { case .unlocked: "unlocked"; case .locked: "locked"; case .sleeping: "sleeping" }
        let text = "Flux \(session.version.version) (\(session.version.build))\nSession: \(phase)\nAccessibility: \(PermissionAccess.status(.accessibility))\nScreen Recording: \(PermissionAccess.status(.screenRecording))\n"
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
    public func dismissCrashNotice() { crashDismissed = true }
    public func openMediaRemoteAdapterLicense() {
        let license = bundle.bundleURL.appendingPathComponent("Contents/Resources/MediaRemoteAdapter-LICENSE.txt")
        guard FileManager.default.fileExists(atPath: license.path) else { failure(.link); return }
        open(license)
    }
    public func openSourceRepository() { open(URL(string: "https://github.com/unknown6003/flux")!) }
    public func assign(_ application: ApplicationID, to group: MenuBarGroup) { menuBar.assign(application, to: group) }
    public func beginArrange() { menuBar.beginArrange() }
    public func endArrange() { menuBar.endArrange() }
    public func showRealIcons() { menuBar.showRealIcons() }
    public func refreshMenuBar() { menuBar.refresh() }
    public func openAccessibilitySettings() { PermissionAccess.openSettings(.accessibility) }
    public func checkAccessibility() { menuBar.checkAccessibility(); notch.refresh(); settings.refresh() }
    public func reviewIdentity(_ application: ApplicationID) { menuBar.reviewIdentity(application) }
    public func setCompactSpacing(_ enabled: Bool) { menuBar.setCompactSpacing(enabled) }

    private func systemPermission(_ kind: NotchAccessKind) -> SystemPermission {
        switch kind { case .calendar: .calendar; case .camera: .camera; case .accessibility: .accessibility }
    }
    private func setAppearance() {
        NSApp.appearance = switch session.preferences.value(for: Preferences.appearance) {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    private func open(_ url: URL) { if !NSWorkspace.shared.open(url) { failure(.link) } }
}
