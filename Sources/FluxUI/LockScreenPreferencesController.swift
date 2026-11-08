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
        let master = toggle("lockScreen.enabled", state.isEnabled, enabled: state.capability != .unavailable) { [weak self] in
            self?.onAction(.setEnabled($0))
        }
        var rows: [NSView] = [FluxUIStyle.row(L("lockScreen.enabled", "Show Flux on the lock screen"), helper: L(
            "lockScreen.enabled.helper",
            "Shows media controls and activities while your Mac is locked. Turning it off keeps the choices below."
        ), control: master)]
        if let status = statusRow() { rows.append(status) }
        let live = state.isEnabled && state.capability == .available
        let parts: [(String, String, String, Bool, (Bool) -> LockScreenPreferencesAction)] = [
            ("lockScreen.nowPlaying", L("lockScreen.nowPlaying", "Now Playing"),
             L("lockScreen.nowPlaying.helper", "Artwork, title, artist and play controls when something is playing."), state.showsNowPlaying, { .setNowPlaying($0) }),
            ("lockScreen.activities", L("lockScreen.activities", "Live activity"),
             L("lockScreen.activities.helper", "The current battery, Bluetooth, calendar or timer activity."), state.showsActivities, { .setActivities($0) }),
            ("lockScreen.unlockSound", L("lockScreen.unlockSound", "Unlock sound"),
             L("lockScreen.unlockSound.helper", "A short sound when you unlock."), state.playsUnlockSound, { .setUnlockSound($0) }),
        ]
        let options = parts.map { id, title, helper, value, action in
            FluxUIStyle.row(title, helper: helper, control: toggle(id, value, enabled: live) { [weak self] in self?.onAction(action($0)) })
        }
        return [
            FluxUIStyle.section(L("settings.lockScreen", "Lock Screen"), rows),
            FluxUIStyle.section(L("lockScreen.show", "Show"), options),
        ]
    }

    private func statusRow() -> NSView? {
        if let code = state.failureCode {
            let retry = button("lockScreen.check", L("lockScreen.check", "Check Again")) { [weak self] in self?.onAction(.checkAgain) }
            return FluxUIStyle.row(L("lockScreen.failed", "Flux could not show on the lock screen"), helper: String(
                format: L("lockScreen.failed.helper", "Last attempt failed (%@). Your choices are kept."), code
            ), control: retry)
        }
        switch state.capability {
        case .available:
            return nil
        case .unavailable:
            return FluxUIStyle.row(L("lockScreen.unavailable", "Not available"), helper: L(
                "lockScreen.unavailable.helper", "This Mac or macOS version can't show Flux on the lock screen. Your choices are kept."
            ), control: nil)
        case .needsPermission:
            let open = button("lockScreen.open", L("lockScreen.open", "Open Settings")) { [weak self] in self?.onAction(.openSystemSettings) }
            let check = button("lockScreen.check", L("lockScreen.check", "Check Again")) { [weak self] in self?.onAction(.checkAgain) }
            let controls = FluxUIStyle.hstack([open, check], spacing: 6)
            return FluxUIStyle.row(L("lockScreen.permission", "Needs permission"), helper: L(
                "lockScreen.permission.helper", "Allow Flux in System Settings, then press Check Again."
            ), control: controls)
        }
    }
}
