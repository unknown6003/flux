public enum SessionPhase: Sendable {
    case unlocked, locked, sleeping
}

public enum FeatureService: CaseIterable, Hashable, Sendable {
    case camera, clipboard, media, calendar, battery, devices, volume, lockScreen
}

public struct FeatureConfiguration: Sendable {
    public var notchEnabled = false
    public var enabledWidgets: Set<Widget> = []
    public var duoEnabled = false
    public var batteryEnabled = false
    public var devicesEnabled = false
    public var calendarActivityEnabled = false
    public var soundHUDEnabled = false
    public var lockScreenEnabled = false
    public var lockScreenMediaEnabled = false
    public var lockScreenActivitiesEnabled = false

    public init() {}

    @MainActor public init(preferences: PreferenceStore) {
        notchEnabled = preferences.value(for: Preferences.notchEnabled)
        enabledWidgets = Set([
            (Widget.nowPlaying, preferences.value(for: Preferences.nowPlayingEnabled)),
            (.shelf, preferences.value(for: Preferences.shelfEnabled)),
            (.calendar, preferences.value(for: Preferences.calendarEnabled)),
            (.mirror, preferences.value(for: Preferences.mirrorEnabled)),
            (.clipboard, preferences.value(for: Preferences.clipboardEnabled))
        ].compactMap { $0.1 ? $0.0 : nil })
        duoEnabled = preferences.value(for: Preferences.duoEnabled)
        batteryEnabled = preferences.value(for: Preferences.batteryEnabled)
        devicesEnabled = preferences.value(for: Preferences.bluetoothEnabled)
        calendarActivityEnabled = preferences.value(for: Preferences.calendarEventEnabled)
        soundHUDEnabled = preferences.value(for: Preferences.soundHUDEnabled)
        lockScreenEnabled = preferences.value(for: Preferences.lockScreenEnabled)
        lockScreenMediaEnabled = preferences.value(for: Preferences.lockScreenNowPlaying)
        lockScreenActivitiesEnabled = preferences.value(for: Preferences.lockScreenActivities)
    }
}

/// One input snapshot decides all live listeners. It constructs no service or permission client.
public struct FeatureDemand: Sendable {
    public var configuration: FeatureConfiguration
    public var phase: SessionPhase
    public var visibleWidget: Widget?
    public var cameraAllowed: Bool
    public var calendarAllowed: Bool

    public init(configuration: FeatureConfiguration, phase: SessionPhase = .unlocked,
                visibleWidget: Widget? = nil, cameraAllowed: Bool = false, calendarAllowed: Bool = false) {
        self.configuration = configuration
        self.phase = phase
        self.visibleWidget = visibleWidget
        self.cameraAllowed = cameraAllowed
        self.calendarAllowed = calendarAllowed
    }

    public var services: Set<FeatureService> {
        let config = configuration
        guard config.notchEnabled, phase != .sleeping else { return [] }
        var result: Set<FeatureService> = []
        if config.lockScreenEnabled { result.insert(.lockScreen) }
        let unlocked = phase == .unlocked
        let lockActivities = config.lockScreenEnabled && config.lockScreenActivitiesEnabled
        if unlocked {
            if config.enabledWidgets.contains(.clipboard) { result.insert(.clipboard) }
            if visibleWidget == .mirror, config.enabledWidgets.contains(.mirror), cameraAllowed {
                result.insert(.camera)
            }
            if config.enabledWidgets.contains(.nowPlaying) { result.insert(.media) }
            if config.soundHUDEnabled { result.insert(.volume) }
        } else if config.lockScreenEnabled, config.lockScreenMediaEnabled {
            result.insert(.media)
        }
        if unlocked || lockActivities {
            if config.batteryEnabled { result.insert(.battery) }
            if config.devicesEnabled { result.insert(.devices) }
            let visibleCalendar = unlocked && (visibleWidget == .calendar || (visibleWidget == .nowPlaying && config.duoEnabled))
            if calendarAllowed, config.enabledWidgets.contains(.calendar),
               config.calendarActivityEnabled || visibleCalendar {
                result.insert(.calendar)
            }
        }
        return result
    }
}

public struct ServiceChanges: Equatable, Sendable {
    public let stop: [FeatureService]
    public let start: [FeatureService]

    public init(active: Set<FeatureService>, requested: Set<FeatureService>) {
        stop = FeatureService.allCases.filter { active.contains($0) && !requested.contains($0) }
        start = FeatureService.allCases.filter { requested.contains($0) && !active.contains($0) }
    }
}
