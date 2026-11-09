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
    /// Open the System Settings pane for this permission. The parent never
    /// shows a macOS permission prompt for this action.
    case openPermissionSettings(PermissionKind)
}

/// Settings › General page. It only shows state and sends actions.
@MainActor
public final class GeneralPreferencesController: FormPageController {
    public private(set) var state: GeneralPreferencesState
    private let onAction: (GeneralPreferencesAction) -> Void

    public init(state: GeneralPreferencesState, onAction: @escaping (GeneralPreferencesAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init()
    }

    /// Shows a new state. It never sends an action.
    public func update(state: GeneralPreferencesState) {
        guard state != self.state else { return }
        self.state = state
        rebuild()
    }

    override func makeSections() -> [NSView] {
        var sections = [startupSection(), shortcutSection()]
        if !state.permissions.isEmpty { sections.append(permissionSection()) }
        return sections
    }

    private func startupSection() -> NSView {
        var rows = [switchRow("general.login", L("general.login", "Launch at login"), help: loginHelp,
                              isOn: state.launchAtLoginRequested, enabled: state.loginStatus != .unavailable) { [weak self] in
            self?.onAction(.setLaunchAtLogin($0))
        }]
        if state.loginStatus == .requiresApproval {
            rows.append(buttonRow("general.login.approve", L("general.login.approval", "Allow in Login Items"),
                                  action: L("general.login.open", "Open Login Items")) { [weak self] in
                self?.onAction(.openLoginItems)
            })
        }
        rows.append(popupRow("general.appearance", L("general.appearance", "Appearance"), [
            (L("general.appearance.system", "System"), Appearance.system),
            (L("general.appearance.light", "Light"), .light),
            (L("general.appearance.dark", "Dark"), .dark),
        ], selected: state.appearance) { [weak self] in self?.onAction(.setAppearance($0)) })
        return FluxUIStyle.section(nil, rows)
    }

    private var loginHelp: String? {
        switch state.loginStatus {
        case .disabled, .enabled: nil
        case .requiresApproval: L("general.login.pending", "Waiting for approval in System Settings.")
        case .unavailable: L("general.login.unavailable", "This copy of Flux can't open at login.")
        }
    }

    private func shortcutSection() -> NSView {
        let reveal = recorder("general.shortcut.reveal", L("general.shortcut.reveal", "Show hidden icons"), state.revealShortcut) { [weak self] in
            self?.onAction(.setRevealShortcut($0))
        }
        let notch = recorder("general.shortcut.notch", L("general.shortcut.notch", "Open the notch"), state.notchShortcut) { [weak self] in
            self?.onAction(.setNotchShortcut($0))
        }
        return FluxUIStyle.section(L("general.shortcuts", "Keyboard shortcuts"), [
            switchRow("general.hotkeys", L("general.hotkeys", "Use global shortcuts"), isOn: state.hotkeysEnabled) { [weak self] in
                self?.onAction(.setHotkeysEnabled($0))
            },
            FluxUIStyle.row(L("general.shortcut.reveal", "Show hidden icons"), helper: conflictText(state.revealConflict), control: reveal),
            FluxUIStyle.row(L("general.shortcut.notch", "Open the notch"), helper: conflictText(state.notchConflict), control: notch),
        ], footer: L("general.shortcuts.footer", "Click a shortcut, then press the new keys."))
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
        case .otherFluxShortcut: L("general.shortcut.duplicate", "The other Flux shortcut uses these keys.")
        case .unavailable: L("general.shortcut.taken", "Another app uses these keys.")
        }
    }

    private func permissionSection() -> NSView {
        let rows: [NSView] = state.permissions.map { row in
            let control: NSView
            switch row.status {
            case .allowed:
                control = FluxUIStyle.value(L("permission.status.allowed", "Allowed"))
            case .unknown:
                control = FluxUIStyle.value(L("permission.status.unknown", "Unknown"))
            case .notAsked, .notAllowed:
                let open = button("general.permission.\(row.kind.rawValue)", L("general.permission.open", "Open Settings")) { [weak self] in
                    self?.onAction(.openPermissionSettings(row.kind))
                }
                open.setAccessibilityLabel(String(format: L("general.permission.open.ax", "Open %@ settings"), row.kind.title))
                control = open
            }
            return FluxUIStyle.row(row.kind.title, helper: row.kind.use, control: control)
        }
        return FluxUIStyle.section(L("general.permissions", "Permissions"), rows)
    }
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
        case .accessibility: L("permission.accessibility.use", "Reads and hides menu bar icons.")
        case .screenRecording: L("permission.screenRecording.use", "Shows real icons in Menu Bar settings.")
        case .calendar: L("permission.calendar.use", "Calendar widget and event alerts.")
        case .camera: L("permission.camera.use", "Mirror widget.")
        case .bluetooth: L("permission.bluetooth.use", "Bluetooth device alerts.")
        }
    }
}
