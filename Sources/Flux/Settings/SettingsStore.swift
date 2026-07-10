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
        self.autoHideOnLaunch = defaults.bool(forKey: Keys.autoHideOnLaunch)
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
    }

    // MARK: General

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var autoHideOnLaunch: Bool {
        didSet { defaults.set(autoHideOnLaunch, forKey: Keys.autoHideOnLaunch) }
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

    // MARK: Defaults

    private static let factoryDefaults: [String: Any] = [
        Keys.launchAtLogin: false,
        Keys.autoHideOnLaunch: true,
        Keys.showAlwaysHiddenSection: true,
        Keys.autoRehide: true,
        Keys.autoRehideDelay: 8.0,
        Keys.enableHotkey: true,
        Keys.automaticUpdateChecks: true,
        Keys.iconStyle: MenuBarIconStyle.chevron.rawValue
    ]

    private enum Keys {
        static let launchAtLogin = "flux.launchAtLogin"
        static let autoHideOnLaunch = "flux.autoHideOnLaunch"
        static let showAlwaysHiddenSection = "flux.showAlwaysHiddenSection"
        static let autoRehide = "flux.autoRehide"
        static let autoRehideDelay = "flux.autoRehideDelay"
        static let enableHotkey = "flux.enableHotkey"
        static let automaticUpdateChecks = "flux.automaticUpdateChecks"
        static let iconStyle = "flux.iconStyle"
    }
}
