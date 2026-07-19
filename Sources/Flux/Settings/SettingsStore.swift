import Foundation
import Combine

/// Single source of truth for user preferences. Backed by `UserDefaults` with a
/// tiny `@Published` surface so SwiftUI and the menu-bar engine both react to
/// changes. No timers, no polling — writes are event-driven and cheap.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.factoryDefaults)

        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.showAlwaysHiddenSection = defaults.bool(forKey: Keys.showAlwaysHiddenSection)
        self.autoRehide = defaults.bool(forKey: Keys.autoRehide)
        self.autoRehideDelay = defaults.double(forKey: Keys.autoRehideDelay)
        self.enableHotkey = defaults.bool(forKey: Keys.enableHotkey)
        self.automaticUpdateChecks = defaults.bool(forKey: Keys.automaticUpdateChecks)
        let styleRaw = defaults.string(forKey: Keys.iconStyle) ?? MenuBarIconStyle.chevron.rawValue
        self.iconStyle = MenuBarIconStyle(rawValue: styleRaw) ?? .chevron
        // Source of truth is the live global default, not a mirrored Flux key, so
        // the toggle reflects the real system state (even if changed elsewhere).
        self.compactMenuBarSpacing = MenuBarSpacing.isCompact
        self.hotkeyShortcut = HotkeyShortcut(
            keyCode: UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode)),
            carbonModifiers: UInt32(defaults.integer(forKey: Keys.hotkeyModifiers))
        )

        self.notchEnabled = defaults.bool(forKey: Keys.notchEnabled)
        let triggerRaw = defaults.string(forKey: Keys.notchExpansionTrigger) ?? NotchExpansionTrigger.hover.rawValue
        self.notchExpansionTrigger = NotchExpansionTrigger(rawValue: triggerRaw) ?? .hover
        self.notchHoverOpenDelay = defaults.double(forKey: Keys.notchHoverOpenDelay)
        self.notchHoverCloseDelay = defaults.double(forKey: Keys.notchHoverCloseDelay)
        self.notchShowInFullscreen = defaults.bool(forKey: Keys.notchShowInFullscreen)
        self.notchWidgetOrder = defaults.stringArray(forKey: Keys.notchWidgetOrder) ?? [WidgetID.nowPlaying.rawValue]
        self.notchNowPlayingEnabled = defaults.bool(forKey: Keys.notchNowPlayingEnabled)
        self.notchShelfEnabled = defaults.bool(forKey: Keys.notchShelfEnabled)
        self.notchShelfExpiryDays = defaults.double(forKey: Keys.notchShelfExpiryDays)
        self.notchCalendarEnabled = defaults.bool(forKey: Keys.notchCalendarEnabled)
        self.notchActivityBatteryEnabled = defaults.bool(forKey: Keys.notchActivityBatteryEnabled)
        self.notchActivityBluetoothEnabled = defaults.bool(forKey: Keys.notchActivityBluetoothEnabled)
        self.notchActivityCalendarEventEnabled = defaults.bool(forKey: Keys.notchActivityCalendarEventEnabled)
        self.notchHudEnabled = defaults.bool(forKey: Keys.notchHudEnabled)
        self.notchHudInterceptEnabled = defaults.bool(forKey: Keys.notchHudInterceptEnabled)
        self.notchMirrorEnabled = defaults.bool(forKey: Keys.notchMirrorEnabled)
        self.notchClipboardEnabled = defaults.bool(forKey: Keys.notchClipboardEnabled)
        self.notchTimersEnabled = defaults.bool(forKey: Keys.notchTimersEnabled)
        self.notchActivityTimerEnabled = defaults.bool(forKey: Keys.notchActivityTimerEnabled)
        self.notchLockScreenExperimentEnabled = defaults.bool(forKey: Keys.notchLockScreenExperimentEnabled)
        self.notchHotkey = HotkeyShortcut(
            keyCode: UInt32(defaults.integer(forKey: Keys.notchHotkeyKeyCode)),
            carbonModifiers: UInt32(defaults.integer(forKey: Keys.notchHotkeyModifiers))
        )
    }

    // MARK: General

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var showAlwaysHiddenSection: Bool {
        didSet { defaults.set(showAlwaysHiddenSection, forKey: Keys.showAlwaysHiddenSection) }
    }

    // MARK: Behaviour

    @Published var autoRehide: Bool {
        didSet { defaults.set(autoRehide, forKey: Keys.autoRehide) }
    }

    /// Seconds before revealed items collapse again. 0 disables the timer.
    @Published var autoRehideDelay: Double {
        didSet { defaults.set(autoRehideDelay, forKey: Keys.autoRehideDelay) }
    }

    @Published var enableHotkey: Bool {
        didSet { defaults.set(enableHotkey, forKey: Keys.enableHotkey) }
    }

    /// The chord that toggles reveal from anywhere. User-recordable in Settings.
    @Published var hotkeyShortcut: HotkeyShortcut {
        didSet {
            defaults.set(Int(hotkeyShortcut.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(hotkeyShortcut.carbonModifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    /// True when macOS refused to register `hotkeyShortcut` — almost always because
    /// another app already owns that chord. Set by `AppDelegate` after each attempt;
    /// deliberately **not** persisted, since it's a fact about the live system, not a
    /// preference. Settings surfaces it so a dead hotkey doesn't fail silently.
    @Published var hotkeyConflict = false

    /// Poll GitHub Releases for a newer Flux on launch and periodically. Purely a
    /// version check over HTTPS — nothing downloads or installs without a click.
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: Keys.automaticUpdateChecks) }
    }

    // MARK: Appearance

    @Published var iconStyle: MenuBarIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Keys.iconStyle) }
    }

    /// Shrinks the global menu-bar item spacing so more icons fit beside the notch.
    /// Not backed by a Flux key — it writes the system's own global default (see
    /// `MenuBarSpacing`), which is the real source of truth.
    @Published var compactMenuBarSpacing: Bool {
        didSet { MenuBarSpacing.apply(compact: compactMenuBarSpacing) }
    }

    // MARK: Notch

    /// Master on/off for the notch panel feature.
    @Published var notchEnabled: Bool {
        didSet { defaults.set(notchEnabled, forKey: Keys.notchEnabled) }
    }

    /// Which gesture opens the notch panel — mirrors `NotchViewModel.expansionTrigger`.
    @Published var notchExpansionTrigger: NotchExpansionTrigger {
        didSet { defaults.set(notchExpansionTrigger.rawValue, forKey: Keys.notchExpansionTrigger) }
    }

    /// Hover-in intent delay before the notch expands, in seconds.
    @Published var notchHoverOpenDelay: Double {
        didSet { defaults.set(notchHoverOpenDelay, forKey: Keys.notchHoverOpenDelay) }
    }

    /// Hover-out intent delay before the notch collapses, in seconds.
    @Published var notchHoverCloseDelay: Double {
        didSet { defaults.set(notchHoverCloseDelay, forKey: Keys.notchHoverCloseDelay) }
    }

    /// Keep the notch panel available over fullscreen apps.
    @Published var notchShowInFullscreen: Bool {
        didSet { defaults.set(notchShowInFullscreen, forKey: Keys.notchShowInFullscreen) }
    }

    /// User-chosen widget cycling order, as `WidgetID` raw values — mirrors
    /// `NotchWidgetRegistry.order`. Stored as `[String]` (rather than
    /// `[WidgetID]`) so a future widget id removed from the app doesn't
    /// prevent the array itself from round-tripping through `UserDefaults`.
    @Published var notchWidgetOrder: [String] {
        didSet { defaults.set(notchWidgetOrder, forKey: Keys.notchWidgetOrder) }
    }

    /// Whether the Now Playing widget is enabled in the notch's cycle.
    @Published var notchNowPlayingEnabled: Bool {
        didSet { defaults.set(notchNowPlayingEnabled, forKey: Keys.notchNowPlayingEnabled) }
    }

    /// Whether the File Shelf widget is enabled in the notch's cycle.
    @Published var notchShelfEnabled: Bool {
        didSet { defaults.set(notchShelfEnabled, forKey: Keys.notchShelfEnabled) }
    }

    /// Whether the Calendar widget is enabled in the notch's cycle.
    @Published var notchCalendarEnabled: Bool {
        didSet { defaults.set(notchCalendarEnabled, forKey: Keys.notchCalendarEnabled) }
    }

    /// How long a shelved file survives before auto-clearing, in days. `0`
    /// means never — mirrors `ShelfStore.expiryInterval` (`nil` there), which
    /// is derived from this value by the wiring agent (`AppDelegate`) rather
    /// than stored redundantly here as a `TimeInterval?` — `UserDefaults`
    /// round-trips a plain `Double` far more simply than an optional.
    @Published var notchShelfExpiryDays: Double {
        didSet { defaults.set(notchShelfExpiryDays, forKey: Keys.notchShelfExpiryDays) }
    }

    /// `notchShelfExpiryDays` translated into the `TimeInterval?` that
    /// `ShelfStore.expiryInterval` actually wants — `0` (the "Never"
    /// setting) means keep forever, which `ShelfStore` spells as `nil`
    /// rather than a magic `0` duration. Computed, not stored: it's a pure
    /// function of `notchShelfExpiryDays`, which is the thing actually
    /// persisted, so `AppDelegate` can read this straight into
    /// `shelfStore.expiryInterval` instead of re-deriving the mapping itself.
    var notchShelfExpiryInterval: TimeInterval? {
        notchShelfExpiryDays > 0 ? notchShelfExpiryDays * 86400 : nil
    }

    /// Whether `PowerMonitor` runs and posts `.battery` live activities —
    /// read by `NotchActivityRouter`, which also requires `notchEnabled`
    /// before actually starting the monitor.
    @Published var notchActivityBatteryEnabled: Bool {
        didSet { defaults.set(notchActivityBatteryEnabled, forKey: Keys.notchActivityBatteryEnabled) }
    }

    /// Whether `BluetoothMonitor` runs and posts `.bluetoothDevice` live
    /// activities — same gating as `notchActivityBatteryEnabled`.
    @Published var notchActivityBluetoothEnabled: Bool {
        didSet { defaults.set(notchActivityBluetoothEnabled, forKey: Keys.notchActivityBluetoothEnabled) }
    }

    /// Whether `CalendarService`'s upcoming events post the "starting soon"
    /// live activity — read by `NotchActivityRouter`, which also requires
    /// `notchEnabled` and Calendar permission before actually starting the
    /// service on this toggle's behalf (see `CalendarService`'s doc comment
    /// on its two independent owners).
    @Published var notchActivityCalendarEventEnabled: Bool {
        didSet { defaults.set(notchActivityCalendarEventEnabled, forKey: Keys.notchActivityCalendarEventEnabled) }
    }

    /// Master on/off for the M5 volume/brightness HUD — governs both modes.
    /// Defaults to `true`: observe mode (`VolumeMonitor`'s CoreAudio
    /// listeners posting alongside the system bezel) needs no permission and
    /// costs nothing at idle, so there's no reason to make a user opt in to
    /// it the way `notchHudInterceptEnabled` requires.
    @Published var notchHudEnabled: Bool {
        didSet { defaults.set(notchHudEnabled, forKey: Keys.notchHudEnabled) }
    }

    /// Opt-in escalation from observe mode to intercept mode — swallowing
    /// volume/brightness keys via `MediaKeyInterceptor` so only the notch HUD
    /// appears, never the system bezel. Defaults to `false`: this needs
    /// Accessibility, an unavoidably scary-looking grant, so it stays off
    /// until the user deliberately turns it on (`NotchActivityRouter` also
    /// independently requires the permission to actually be granted before
    /// honoring this toggle — see `applyHUDState`).
    @Published var notchHudInterceptEnabled: Bool {
        didSet { defaults.set(notchHudInterceptEnabled, forKey: Keys.notchHudInterceptEnabled) }
    }

    /// Whether the Mirror widget (a live camera preview) is enabled in the
    /// notch's cycle. Defaults to `true` — like every other widget, showing
    /// the widget itself needs no permission; it's `MirrorWidget`'s own
    /// permission-gated view (and `CameraService`'s own authorization check)
    /// that keeps the camera off until Camera access is actually granted.
    @Published var notchMirrorEnabled: Bool {
        didSet { defaults.set(notchMirrorEnabled, forKey: Keys.notchMirrorEnabled) }
    }

    /// Whether `ClipboardMonitor` collects clipboard history at all. Defaults
    /// to `false`, unlike every other notch-suite toggle — clipboard content
    /// routinely includes passwords and other sensitive text a user only
    /// meant to paste once, so history collection is opt-in rather than
    /// on-by-default the way a glanceable widget normally would be. Also
    /// gates the Clipboard widget's own enabled state (see `AppDelegate`'s
    /// wiring) — there's no reason to show an empty history widget when
    /// collection itself is off.
    @Published var notchClipboardEnabled: Bool {
        didSet { defaults.set(notchClipboardEnabled, forKey: Keys.notchClipboardEnabled) }
    }

    /// Whether the Timers widget is enabled in the notch's cycle.
    @Published var notchTimersEnabled: Bool {
        didSet { defaults.set(notchTimersEnabled, forKey: Keys.notchTimersEnabled) }
    }

    /// Whether a finished timer posts a wing (plus plays a sound) and a
    /// running timer shows an ambient countdown wing — read by
    /// `NotchActivityRouter`, which also requires `notchEnabled` and
    /// somewhere to actually present before showing either.
    @Published var notchActivityTimerEnabled: Bool {
        didSet { defaults.set(notchActivityTimerEnabled, forKey: Keys.notchActivityTimerEnabled) }
    }

    /// EXPERIMENTAL — master on/off for `LockScreenPresenter`'s notch
    /// silhouette on the macOS lock screen. Defaults to `false`: this rides
    /// on undocumented lock-screen notification names and drawing above the
    /// lock screen's own shield window level (see that type's own doc
    /// comment on why), so it's opt-in rather than on-by-default like the
    /// rest of the notch suite.
    @Published var notchLockScreenExperimentEnabled: Bool {
        didSet { defaults.set(notchLockScreenExperimentEnabled, forKey: Keys.notchLockScreenExperimentEnabled) }
    }

    /// The chord that toggles the notch panel from anywhere — independent of
    /// `hotkeyShortcut` (the menu-bar reveal toggle). User-recordable in Settings.
    @Published var notchHotkey: HotkeyShortcut {
        didSet {
            defaults.set(Int(notchHotkey.keyCode), forKey: Keys.notchHotkeyKeyCode)
            defaults.set(Int(notchHotkey.carbonModifiers), forKey: Keys.notchHotkeyModifiers)
        }
    }

    /// True when macOS refused to register `notchHotkey` — see `hotkeyConflict`'s
    /// doc comment; same reasoning, kept as a separate flag since the two hotkeys
    /// register (and can conflict) independently.
    @Published var notchHotkeyConflict = false

    // MARK: Defaults

    private static let factoryDefaults: [String: Any] = [
        Keys.launchAtLogin: false,
        Keys.showAlwaysHiddenSection: true,
        Keys.autoRehide: true,
        Keys.autoRehideDelay: 8.0,
        Keys.enableHotkey: true,
        Keys.automaticUpdateChecks: true,
        Keys.iconStyle: MenuBarIconStyle.chevron.rawValue,
        Keys.hotkeyKeyCode: Int(HotkeyShortcut.default.keyCode),
        Keys.hotkeyModifiers: Int(HotkeyShortcut.default.carbonModifiers),
        Keys.notchEnabled: true,
        Keys.notchExpansionTrigger: NotchExpansionTrigger.hover.rawValue,
        Keys.notchHoverOpenDelay: 0.15,
        Keys.notchHoverCloseDelay: 0.40,
        Keys.notchShowInFullscreen: true,
        Keys.notchWidgetOrder: [WidgetID.nowPlaying.rawValue, WidgetID.shelf.rawValue, WidgetID.calendar.rawValue,
                                WidgetID.mirror.rawValue, WidgetID.timers.rawValue, WidgetID.clipboard.rawValue],
        Keys.notchNowPlayingEnabled: true,
        Keys.notchShelfEnabled: true,
        Keys.notchShelfExpiryDays: 0.0,
        Keys.notchCalendarEnabled: true,
        Keys.notchActivityBatteryEnabled: true,
        Keys.notchActivityBluetoothEnabled: true,
        Keys.notchActivityCalendarEventEnabled: true,
        Keys.notchHudEnabled: true,
        Keys.notchHudInterceptEnabled: false,
        Keys.notchMirrorEnabled: true,
        Keys.notchClipboardEnabled: false,
        Keys.notchTimersEnabled: true,
        Keys.notchActivityTimerEnabled: true,
        Keys.notchLockScreenExperimentEnabled: false,
        Keys.notchHotkeyKeyCode: Int(HotkeyShortcut.notchDefault.keyCode),
        Keys.notchHotkeyModifiers: Int(HotkeyShortcut.notchDefault.carbonModifiers),
    ]

    private enum Keys {
        static let launchAtLogin = "flux.launchAtLogin"
        static let showAlwaysHiddenSection = "flux.showAlwaysHiddenSection"
        static let autoRehide = "flux.autoRehide"
        static let autoRehideDelay = "flux.autoRehideDelay"
        static let enableHotkey = "flux.enableHotkey"
        static let automaticUpdateChecks = "flux.automaticUpdateChecks"
        static let iconStyle = "flux.iconStyle"
        static let hotkeyKeyCode = "flux.hotkey.keyCode"
        static let hotkeyModifiers = "flux.hotkey.modifiers"
        static let notchEnabled = "flux.notch.enabled"
        static let notchExpansionTrigger = "flux.notch.expansionTrigger"
        static let notchHoverOpenDelay = "flux.notch.hoverOpenDelay"
        static let notchHoverCloseDelay = "flux.notch.hoverCloseDelay"
        static let notchShowInFullscreen = "flux.notch.showInFullscreen"
        static let notchWidgetOrder = "flux.notch.widgetOrder"
        static let notchNowPlayingEnabled = "flux.notch.nowPlayingEnabled"
        static let notchShelfEnabled = "flux.notch.shelf.enabled"
        static let notchShelfExpiryDays = "flux.notch.shelf.expiryDays"
        static let notchCalendarEnabled = "flux.notch.calendar.enabled"
        static let notchActivityBatteryEnabled = "flux.notch.activities.battery"
        static let notchActivityBluetoothEnabled = "flux.notch.activities.bluetooth"
        static let notchActivityCalendarEventEnabled = "flux.notch.activities.calendarEvent"
        static let notchHudEnabled = "flux.notch.hud.enabled"
        static let notchHudInterceptEnabled = "flux.notch.hud.intercept"
        static let notchMirrorEnabled = "flux.notch.mirror.enabled"
        static let notchClipboardEnabled = "flux.notch.clipboard.enabled"
        static let notchTimersEnabled = "flux.notch.timers.enabled"
        static let notchActivityTimerEnabled = "flux.notch.activities.timer"
        static let notchLockScreenExperimentEnabled = "flux.notch.lockScreenExperiment"
        static let notchHotkeyKeyCode = "flux.notch.hotkey.keyCode"
        static let notchHotkeyModifiers = "flux.notch.hotkey.modifiers"
    }
}
