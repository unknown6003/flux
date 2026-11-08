import AppKit
import FluxCore

/// What macOS reports for the login item. The parent maps `SMAppService`
/// to this. FluxUI does not import ServiceManagement.
public enum LoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

/// The parent's result for one global shortcut. Each shortcut has its own.
public enum ShortcutConflict: Equatable, Sendable {
    case clear
    /// The other Flux shortcut uses the same keys.
    case otherFluxShortcut
    /// macOS or another app refused or holds the keys.
    case unavailable
}

/// A macOS permission that one Flux feature uses.
public enum PermissionKind: String, CaseIterable, Equatable, Sendable {
    case accessibility, screenRecording, calendar, camera, bluetooth
}

/// What the parent last read for one permission. FluxUI never asks macOS.
public enum PermissionStatus: Equatable, Sendable {
    case allowed
    case notAsked
    case notAllowed
    /// The parent could not read the status.
    case unknown
}

public struct PermissionRow: Equatable, Sendable {
    public let kind: PermissionKind
    public let status: PermissionStatus

    public init(kind: PermissionKind, status: PermissionStatus) {
        self.kind = kind
        self.status = status
    }
}

/// Everything Settings › General shows. The parent sends a new value after each change.
public struct GeneralPreferencesState: Equatable, Sendable {
    public let launchAtLoginRequested: Bool
    public let loginStatus: LoginStatus
    public let hotkeysEnabled: Bool
    public let revealShortcut: Shortcut
    public let revealConflict: ShortcutConflict
    public let notchShortcut: Shortcut
    public let notchConflict: ShortcutConflict
    public let appearance: Appearance
    public let automaticUpdateChecks: Bool
    public let update: UpdateStatus
    public let analytics: AnalyticsStatus
    /// Rows in the order the parent wants. Empty hides the section.
    public let permissions: [PermissionRow]

    public init(
        launchAtLoginRequested: Bool,
        loginStatus: LoginStatus,
        hotkeysEnabled: Bool,
        revealShortcut: Shortcut,
        revealConflict: ShortcutConflict = .clear,
        notchShortcut: Shortcut,
        notchConflict: ShortcutConflict = .clear,
        appearance: Appearance,
        automaticUpdateChecks: Bool,
        update: UpdateStatus = .idle,
        analytics: AnalyticsStatus = .off,
        permissions: [PermissionRow] = []
    ) {
        self.launchAtLoginRequested = launchAtLoginRequested
        self.loginStatus = loginStatus
        self.hotkeysEnabled = hotkeysEnabled
        self.revealShortcut = revealShortcut
        self.revealConflict = revealConflict
        self.notchShortcut = notchShortcut
        self.notchConflict = notchConflict
        self.appearance = appearance
        self.automaticUpdateChecks = automaticUpdateChecks
        self.update = update
        self.analytics = analytics
        self.permissions = permissions
    }
}

/// Requests from Settings › General. The parent saves, registers and checks.
public enum GeneralPreferencesAction: Equatable, Sendable {
    case setLaunchAtLogin(Bool)
    case openLoginItems
    case setHotkeysEnabled(Bool)
    case setRevealShortcut(Shortcut)
    case setNotchShortcut(Shortcut)
    case setAppearance(Appearance)
    case setAutomaticUpdateChecks(Bool)
    case checkForUpdates
    case installUpdate
    case setAnalyticsEnabled(Bool)
    case resetAnalyticsID
    /// Open the System Settings pane for this permission. The parent never
    /// shows a macOS permission prompt for this action.
    case openPermissionSettings(PermissionKind)
}

/// Settings › General page. It only shows state and sends actions.
@MainActor
public final class GeneralPreferencesController: FormPageController {
    public private(set) var state: GeneralPreferencesState
    private let onAction: (GeneralPreferencesAction) -> Void
    private let analytics: AnalyticsSettingsView

    public init(state: GeneralPreferencesState, onAction: @escaping (GeneralPreferencesAction) -> Void) {
        self.state = state
        self.onAction = onAction
        analytics = AnalyticsSettingsView(status: state.analytics)
        super.init()
        analytics.onSetEnabled = { [weak self] in self?.onAction(.setAnalyticsEnabled($0)) }
        analytics.onResetID = { [weak self] in self?.onAction(.resetAnalyticsID) }
    }

    /// Shows a new state. It never sends an action.
    public func update(state: GeneralPreferencesState) {
        guard state != self.state else { return }
        self.state = state
        analytics.update(state.analytics)
        rebuild()
    }

    override func makeSections() -> [NSView] {
        var sections = [startupSection(), shortcutSection(), appearanceSection(), updateSection()]
        if !state.permissions.isEmpty { sections.append(permissionSection()) }
        sections.append(analytics)
        return sections
    }

    private func permissionSection() -> NSView {
        let rows: [NSView] = state.permissions.map { row in
            let id = "general.permission.\(row.kind.rawValue)"
            let open: NSView?
            if row.status == .allowed {
                open = nil
            } else {
                let control = button(id, L("general.permission.open", "Open Settings")) { [weak self] in
                    self?.onAction(.openPermissionSettings(row.kind))
                }
                control.setAccessibilityLabel(String(format: L("general.permission.open.ax", "Open %@ settings"), row.kind.title))
                open = control
            }
            let helper = row.kind.use + " " + row.status.text
            return FluxUIStyle.row(row.kind.title, helper: helper, control: open)
        }
        return FluxUIStyle.section(L("general.permissions", "Permissions"), rows)
    }

    private func startupSection() -> NSView {
        let login = toggle("general.login", state.launchAtLoginRequested, enabled: state.loginStatus != .unavailable) { [weak self] in
            self?.onAction(.setLaunchAtLogin($0))
        }
        var rows: [NSView] = [FluxUIStyle.row(L("general.login", "Launch at login"), helper: loginText, control: login)]
        if state.loginStatus == .requiresApproval {
            let open = button("general.login.approve", L("general.login.open", "Open Login Items")) { [weak self] in
                self?.onAction(.openLoginItems)
            }
            rows.append(FluxUIStyle.row(
                L("general.login.approval", "Needs approval in Login Items"),
                helper: L("general.login.approval.helper", "Turn on Flux in System Settings › General › Login Items."),
                control: open
            ))
        }
        return FluxUIStyle.section(L("general.startup", "Startup"), rows)
    }

    private var loginText: String {
        switch state.loginStatus {
        case .disabled: L("general.login.off", "Flux does not open at login.")
        case .enabled: L("general.login.on", "Flux opens at login.")
        case .requiresApproval: L("general.login.pending", "macOS has not approved Flux yet.")
        case .unavailable: L("general.login.unavailable", "This copy of Flux can't open at login.")
        }
    }

    private func shortcutSection() -> NSView {
        let enabled = toggle("general.hotkeys", state.hotkeysEnabled) { [weak self] in
            self?.onAction(.setHotkeysEnabled($0))
        }
        let reveal = recorder("general.shortcut.reveal", L("general.shortcut.reveal", "Show hidden icons"), state.revealShortcut) { [weak self] in
            self?.onAction(.setRevealShortcut($0))
        }
        let notch = recorder("general.shortcut.notch", L("general.shortcut.notch", "Open the notch panel"), state.notchShortcut) { [weak self] in
            self?.onAction(.setNotchShortcut($0))
        }
        return FluxUIStyle.section(L("general.shortcuts", "Keyboard shortcuts"), [
            FluxUIStyle.row(L("general.hotkeys", "Use global shortcuts"), helper: L(
                "general.hotkeys.helper",
                "Click a shortcut, then type new keys. Esc cancels. Turning this off keeps your shortcuts."
            ), control: enabled),
            FluxUIStyle.row(L("general.shortcut.reveal", "Show hidden icons"), helper: conflictText(state.revealConflict), control: reveal),
            FluxUIStyle.row(L("general.shortcut.notch", "Open the notch panel"), helper: conflictText(state.notchConflict), control: notch),
        ])
    }

    private func recorder(_ id: String, _ name: String, _ shortcut: Shortcut, _ handler: @escaping (Shortcut) -> Void) -> NSView {
        let view = ShortcutRecorderView(name: name)
        view.identifier = .init(id)
        view.shortcut = shortcut
        view.isEnabled = state.hotkeysEnabled
        view.onRecord = handler
        return view
    }

    private func conflictText(_ conflict: ShortcutConflict) -> String? {
        switch conflict {
        case .clear: nil
        case .otherFluxShortcut: L("general.shortcut.duplicate", "The other Flux shortcut uses these keys. Choose different keys.")
        case .unavailable: L("general.shortcut.taken", "macOS or another app uses these keys. Choose different keys.")
        }
    }

    private func appearanceSection() -> NSView {
        let options: [(String, Appearance)] = [
            (L("general.appearance.dark", "Dark"), .dark),
            (L("general.appearance.light", "Light"), .light),
            (L("general.appearance.system", "System"), .system),
        ]
        let choice = popup("general.appearance", options, selected: state.appearance) { [weak self] in
            self?.onAction(.setAppearance($0))
        }
        return FluxUIStyle.section(L("general.appearance.header", "Appearance"), [
            FluxUIStyle.row(L("general.appearance", "Appearance"), control: choice),
        ])
    }

    private func updateSection() -> NSView {
        let auto = toggle("general.updates.auto", state.automaticUpdateChecks) { [weak self] in
            self?.onAction(.setAutomaticUpdateChecks($0))
        }
        return FluxUIStyle.section(L("general.updates", "Updates"), [
            FluxUIStyle.row(L("general.updates.auto", "Check for updates automatically"), control: auto),
            updateRow(self, id: "general.updates.action", status: state.update) { [weak self] in self?.onAction($0 ? .installUpdate : .checkForUpdates) },
        ])
    }
}

/// The update row shared by General and About. `handler(true)` means install.
@MainActor
func updateRow(_ page: FormPageController, id: String, status: UpdateStatus, _ handler: @escaping (Bool) -> Void) -> NSView {
    let install: Bool
    if case .available = status { install = true } else { install = false }
    let title = install ? L("update.install", "Install Update") : L("update.check", "Check for Updates")
    let action = page.button(id, title, enabled: !status.isBusy) { handler(install) }
    let text = status.text
    return FluxUIStyle.row(L("update.title", "Flux updates"), helper: text.isEmpty ? nil : text, control: action)
}

extension PermissionKind {
    var title: String {
        switch self {
        case .accessibility: L("permission.accessibility", "Accessibility")
        case .screenRecording: L("permission.screenRecording", "Screen Recording")
        case .calendar: L("permission.calendar", "Calendar")
        case .camera: L("permission.camera", "Camera")
        case .bluetooth: L("permission.bluetooth", "Bluetooth")
        }
    }

    /// The feature that uses this permission. Fixed text only.
    var use: String {
        switch self {
        case .accessibility: L("permission.accessibility.use", "Menu Bar uses this to read your menu bar icons.")
        case .screenRecording: L("permission.screenRecording.use", "Menu Bar uses this only for Show Real Icons.")
        case .calendar: L("permission.calendar.use", "The Calendar widget and event alerts use this.")
        case .camera: L("permission.camera.use", "Mirror uses this while it is open.")
        case .bluetooth: L("permission.bluetooth.use", "Bluetooth device alerts use this.")
        }
    }
}

extension PermissionStatus {
    var text: String {
        switch self {
        case .allowed: L("permission.status.allowed", "Allowed.")
        case .notAsked: L("permission.status.notAsked", "Not asked yet.")
        case .notAllowed: L("permission.status.notAllowed", "Not allowed. Change it in System Settings › Privacy & Security.")
        case .unknown: L("permission.status.unknown", "Flux can't read this status now.")
        }
    }
}
