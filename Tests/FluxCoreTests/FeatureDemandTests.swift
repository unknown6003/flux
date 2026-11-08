import Testing
@testable import FluxCore

@Test func cameraDemandEndsWhenMirrorClosesOrTheSessionLocks() {
    var config = FeatureConfiguration()
    config.notchEnabled = true
    config.enabledWidgets = [.mirror]
    var state = FeatureDemand(configuration: config, visibleWidget: .mirror, cameraAllowed: true)
    #expect(state.services == [.camera])
    let active = state.services
    state.visibleWidget = .shelf
    #expect(ServiceChanges(active: active, requested: state.services).stop == [.camera])
    state.visibleWidget = .mirror
    state.phase = .locked
    #expect(state.services.isEmpty)
    state.phase = .unlocked
    state.cameraAllowed = false
    #expect(state.services.isEmpty)
    state.cameraAllowed = true
    state.configuration.enabledWidgets = []
    #expect(state.services.isEmpty)
}

@Test func backgroundDemandsKeepUsefulFeaturesWithoutRunningPrivateWidgets() {
    var config = FeatureConfiguration()
    config.notchEnabled = true
    config.enabledWidgets = [.clipboard, .calendar, .mirror, .nowPlaying]
    config.batteryEnabled = true
    config.devicesEnabled = true
    config.calendarActivityEnabled = true
    config.soundHUDEnabled = true
    var state = FeatureDemand(configuration: config, calendarAllowed: true)
    #expect(state.services == [.clipboard, .media, .calendar, .battery, .devices, .volume])
    state.phase = .locked
    #expect(state.services.isEmpty)
    state.configuration.lockScreenEnabled = true
    state.configuration.lockScreenMediaEnabled = true
    state.configuration.lockScreenActivitiesEnabled = true
    #expect(state.services == [.lockScreen, .media, .calendar, .battery, .devices])
    state.phase = .sleeping
    #expect(state.services.isEmpty)
    state.phase = .unlocked
    state.configuration.notchEnabled = false
    #expect(state.services.isEmpty)
}

@Test func calendarAndMediaServicesHaveOneSharedDemandAcrossWidgetsAndWings() {
    var config = FeatureConfiguration()
    config.notchEnabled = true
    config.enabledWidgets = [.calendar, .nowPlaying]
    config.duoEnabled = true
    var state = FeatureDemand(configuration: config, visibleWidget: .nowPlaying, calendarAllowed: true)
    #expect(state.services == [.media, .calendar])
    let active = state.services
    state.visibleWidget = .calendar
    let changes = ServiceChanges(active: active, requested: state.services)
    #expect(changes.stop.isEmpty)
    #expect(changes.start.isEmpty)
    state.visibleWidget = nil
    #expect(state.services == [.media])
    state.configuration.calendarActivityEnabled = true
    #expect(state.services == [.media, .calendar])
    state.calendarAllowed = false
    #expect(state.services == [.media])
}
