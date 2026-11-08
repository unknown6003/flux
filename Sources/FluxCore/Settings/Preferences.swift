public enum Appearance: String, CaseIterable, Sendable {
    case dark, light, system
}

public enum MenuBarIcon: String, CaseIterable, Sendable {
    case chevron, dot, line
}

public enum ExpansionTrigger: String, CaseIterable, Sendable {
    case hover, click
}

public enum Widget: String, CaseIterable, Sendable {
    case nowPlaying, shelf, calendar, mirror, clipboard
}

public enum Preferences {
    public static let launchAtLogin = Preference.boolean("flux.launchAtLogin", false)
    public static let alwaysHiddenEnabled = Preference.boolean("flux.showAlwaysHiddenSection", true)
    public static let autoRehide = Preference.boolean("flux.autoRehide", true)
    public static let autoRehideDelay = Preference.duration("flux.autoRehideDelay", 8)
    public static let enableHotkey = Preference.boolean("flux.enableHotkey", true)
    public static let automaticUpdateChecks = Preference.boolean("flux.automaticUpdateChecks", true)
    public static let appearance = Preference.choice("flux.appearance", Appearance.dark)
    public static let iconStyle = Preference.choice("flux.iconStyle", MenuBarIcon.chevron)
    public static let hotkeyKeyCode = Preference.unsignedInteger("flux.hotkey.keyCode", 3)
    public static let hotkeyModifiers = Preference.unsignedInteger("flux.hotkey.modifiers", 6400)
    public static let notchEnabled = Preference.boolean("flux.notch.enabled", true)
    public static let expansionTrigger = Preference.choice("flux.notch.expansionTrigger", ExpansionTrigger.hover)
    public static let hoverCloseDelay = Preference.duration("flux.notch.hoverCloseDelay", 0.4)
    public static let showInFullscreen = Preference.boolean("flux.notch.showInFullscreen", true)
    public static let widgetOrder = Preference.strings("flux.notch.widgetOrder", Widget.allCases.map(\.rawValue))
    public static let nowPlayingEnabled = Preference.boolean("flux.notch.nowPlayingEnabled", true)
    public static let shelfEnabled = Preference.boolean("flux.notch.shelf.enabled", true)
    public static let shelfExpiryDays = Preference.duration("flux.notch.shelf.expiryDays", 0)
    public static let calendarEnabled = Preference.boolean("flux.notch.calendar.enabled", true)
    public static let batteryEnabled = Preference.boolean("flux.notch.activities.battery", true)
    public static let bluetoothEnabled = Preference.boolean("flux.notch.activities.bluetooth", true)
    public static let calendarEventEnabled = Preference.boolean("flux.notch.activities.calendarEvent", true)
    public static let duoEnabled = Preference.boolean("flux.notch.duo", false)
    public static let mirrorEnabled = Preference.boolean("flux.notch.mirror.enabled", true)
    public static let clipboardEnabled = Preference.boolean("flux.notch.clipboard.enabled", true, new: false)
    public static let clipboardPersistenceEnabled = Preference.boolean("flux.notch.clipboard.persistence.enabled", true, new: false)
    public static let timerEnabled = Preference.boolean("flux.notch.activities.timer", true)
    public static let soundHUDEnabled = Preference.boolean("flux.notch.activities.soundHUD", true)
    public static let lockScreenEnabled = Preference.boolean("flux.notch.lockScreenExperiment", true, new: false)
    public static let lockScreenNowPlaying = Preference.boolean("flux.notch.lockScreen.nowPlaying", true)
    public static let lockScreenActivities = Preference.boolean("flux.notch.lockScreen.activities", true)
    public static let lockScreenUnlockSound = Preference.boolean("flux.notch.lockScreen.unlockSound", true)
    public static let notchHotkeyKeyCode = Preference.unsignedInteger("flux.notch.hotkey.keyCode", 45)
    public static let notchHotkeyModifiers = Preference.unsignedInteger("flux.notch.hotkey.modifiers", 6400)

    static let registrations: [PreferenceRegistration] = [
        launchAtLogin.registration,
        alwaysHiddenEnabled.registration,
        autoRehide.registration,
        autoRehideDelay.registration,
        enableHotkey.registration,
        automaticUpdateChecks.registration,
        appearance.registration,
        iconStyle.registration,
        hotkeyKeyCode.registration,
        hotkeyModifiers.registration,
        notchEnabled.registration,
        expansionTrigger.registration,
        hoverCloseDelay.registration,
        showInFullscreen.registration,
        widgetOrder.registration,
        nowPlayingEnabled.registration,
        shelfEnabled.registration,
        shelfExpiryDays.registration,
        calendarEnabled.registration,
        batteryEnabled.registration,
        bluetoothEnabled.registration,
        calendarEventEnabled.registration,
        duoEnabled.registration,
        mirrorEnabled.registration,
        clipboardEnabled.registration,
        clipboardPersistenceEnabled.registration,
        timerEnabled.registration,
        soundHUDEnabled.registration,
        lockScreenEnabled.registration,
        lockScreenNowPlaying.registration,
        lockScreenActivities.registration,
        lockScreenUnlockSound.registration,
        notchHotkeyKeyCode.registration,
        notchHotkeyModifiers.registration
    ]
}
