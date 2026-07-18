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
        Keys.notchWidgetOrder: [WidgetID.nowPlaying.rawValue],
        Keys.notchNowPlayingEnabled: true,
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
        static let notchHotkeyKeyCode = "flux.notch.hotkey.keyCode"
        static let notchHotkeyModifiers = "flux.notch.hotkey.modifiers"
    }
}
