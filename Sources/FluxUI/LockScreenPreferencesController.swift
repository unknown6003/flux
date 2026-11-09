import AppKit

/// The parent's fixed reading of whether Flux can show on the lock screen.
public enum LockScreenCapability: Equatable, Sendable {
    case available
    case unavailable
    case needsPermission
}

/// Everything Settings › Lock Screen shows. The parent sends a new value after each change.
public struct LockScreenPreferencesState: Equatable, Sendable {
    /// `flux.notch.lockScreenExperiment`. Off for new profiles.
    public let isEnabled: Bool
    public let showsNowPlaying: Bool
    public let showsActivities: Bool
    public let playsUnlockSound: Bool
    public let capability: LockScreenCapability
    /// A short code from the parent's last failed attempt, or nil.
    public let failureCode: String?

    public init(
        isEnabled: Bool,
        showsNowPlaying: Bool,
        showsActivities: Bool,
        playsUnlockSound: Bool,
        capability: LockScreenCapability,
        failureCode: String?
    ) {
        self.isEnabled = isEnabled
        self.showsNowPlaying = showsNowPlaying
        self.showsActivities = showsActivities
        self.playsUnlockSound = playsUnlockSound
        self.capability = capability
        self.failureCode = failureCode
    }
}

/// Requests from Settings › Lock Screen. The parent saves and checks.
public enum LockScreenPreferencesAction: Equatable, Sendable {
    case setEnabled(Bool)
    case setNowPlaying(Bool)
    case setActivities(Bool)
    case setUnlockSound(Bool)
    case openSystemSettings
    case checkAgain
}

/// Settings › Lock Screen page. It only shows state and sends actions.
@MainActor
public final class LockScreenPreferencesController: FormPageController {
    public private(set) var state: LockScreenPreferencesState
    private let onAction: (LockScreenPreferencesAction) -> Void

    public init(state: LockScreenPreferencesState, onAction: @escaping (LockScreenPreferencesAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init()
    }

    /// Shows a new state. It never sends an action.
    public func update(state: LockScreenPreferencesState) {
        guard state != self.state else { return }
        self.state = state
        rebuild()
    }

    override func makeSections() -> [NSView] {
        var rows = [switchRow("lockScreen.enabled", L("lockScreen.enabled", "Show on the lock screen"), help: L(
            "lockScreen.enabled.helper", "Media and activities while your Mac is locked."
        ), isOn: state.isEnabled, enabled: state.capability != .unavailable) { [weak self] in self?.onAction(.setEnabled($0)) }]
        if let status = statusRow() { rows.append(status) }
        let live = state.isEnabled && state.capability == .available
        return [
            FluxUIStyle.section(nil, rows),
            FluxUIStyle.section(L("lockScreen.show", "Show"), [
                switchRow("lockScreen.nowPlaying", L("lockScreen.nowPlaying", "Now Playing"), help: L(
                    "lockScreen.nowPlaying.helper", "Artwork and play controls."
                ), isOn: state.showsNowPlaying, enabled: live) { [weak self] in self?.onAction(.setNowPlaying($0)) },
                switchRow("lockScreen.activities", L("lockScreen.activities", "Live activity"), help: L(
                    "lockScreen.activities.helper", "Battery, Bluetooth, calendar or timer."
                ), isOn: state.showsActivities, enabled: live) { [weak self] in self?.onAction(.setActivities($0)) },
                switchRow("lockScreen.unlockSound", L("lockScreen.unlockSound", "Unlock sound"),
                          isOn: state.playsUnlockSound, enabled: live) { [weak self] in self?.onAction(.setUnlockSound($0)) },
            ]),
        ]
    }

    private func statusRow() -> NSView? {
        if let code = state.failureCode {
            return buttonRow("lockScreen.check", L("lockScreen.failed", "Could not show on the lock screen"), help: String(
                format: L("lockScreen.failed.helper", "Error %@. Your choices are kept."), code
            ), action: L("lockScreen.check", "Check Again")) { [weak self] in self?.onAction(.checkAgain) }
        }
        switch state.capability {
        case .available:
            return nil
        case .unavailable:
            return FluxUIStyle.row(L("lockScreen.unavailable", "Not available on this Mac"), helper: nil, control: nil)
        case .needsPermission:
            let open = button("lockScreen.open", L("lockScreen.open", "Open Settings")) { [weak self] in self?.onAction(.openSystemSettings) }
            let check = button("lockScreen.check", L("lockScreen.check", "Check Again")) { [weak self] in self?.onAction(.checkAgain) }
            return FluxUIStyle.row(L("lockScreen.permission", "Needs permission"), helper: L(
                "lockScreen.permission.helper", "Allow Flux in System Settings."
            ), control: FluxUIStyle.hstack([check, open], spacing: 8))
        }
    }
}
