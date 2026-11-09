import Foundation
import Testing
import FluxCore
import FluxPlatform
@testable import FluxApplication

@MainActor private final class CoordinatorClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite(.serialized)
struct ActivityCoordinatorTests {
    @Test @MainActor func soundHUDShowsAnAcknowledgedBoundaryKeyButIgnoresStartupVolume() throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let owner = ActivityCoordinator(preferences: preferences, publish: { _, _, _, _ in }, timerCompleted: { _ in })
        defer { owner.stop() }
        owner.start()
        let full = VolumeSnapshot(level: 1, muted: false, adjustable: true)
        owner.receiveVolume(full)
        owner.receiveVolume(full)
        #expect(owner.queue.current == nil)
        owner.receiveVolume(full, force: true)
        #expect(owner.queue.current?.kind == .soundHUD)
        #expect(owner.queue.current?.trailing == .soundGauge(value: 1, symbol: "speaker.wave.3.fill"))
    }

    @Test @MainActor func overflowScansRespectDismissalUntilTheBarFitsAgain() throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let owner = ActivityCoordinator(preferences: preferences, publish: { _, _, _, _ in }, timerCompleted: { _ in })
        defer { owner.stop() }
        owner.start()
        owner.setOverflowCount(3)
        owner.perform(.dismissActivity)
        owner.setOverflowCount(3)
        owner.setOverflowCount(4)
        #expect(owner.queue.current == nil)
        #expect(owner.queue.restorableCount == 1)
        owner.setOverflowCount(0)
        owner.setOverflowCount(2)
        #expect(owner.queue.current?.trailing == .text("2"))
        #expect(owner.queue.restorableCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func dismissingCompletionStillRestoresTheNextTimerAtItsDeadline() async throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        var completions = 0
        let owner = ActivityCoordinator(preferences: preferences, publish: { _, _, _, _ in },
                                        timerCompleted: { _ in completions += 1 })
        defer { owner.stop() }
        owner.start()
        owner.setPresenting(true)
        try owner.timers.start(duration: 0.05, label: "First")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while completions == 0, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completions == 1)
        try owner.timers.start(duration: 120, label: "Second")
        owner.perform(.dismissActivity)
        #expect(owner.queue.current == nil)
        // Test actual delivery without assuming the shared CI main actor
        // dispatches this callback within an arbitrary 200 ms window. The
        // clock-driven case below separately checks the ten-second policy.
        let restorationDeadline = clock.now.advanced(by: .seconds(12))
        while owner.queue.current?.priority != 110, clock.now < restorationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(owner.queue.current?.kind == .timer)
        #expect(owner.queue.current?.priority == 110)
        #expect(owner.timers.timers.count == 1)
    }

    @Test @MainActor func lowBatteryTicksRespectDismissalAndAPlugIsANewNotice() throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let owner = ActivityCoordinator(preferences: preferences, publish: { _, _, _, _ in }, timerCompleted: { _ in })
        defer { owner.stop() }
        owner.start()
        owner.receiveBattery(.init(percent: 20, charging: false, externalPower: false))
        #expect(owner.queue.current?.tint == .warning)
        owner.perform(.dismissActivity)
        owner.receiveBattery(.init(percent: 19, charging: false, externalPower: false))
        #expect(owner.queue.current == nil)
        #expect(owner.queue.restorableCount == 1)
        owner.receiveBattery(.init(percent: 19, charging: true, externalPower: true))
        #expect(owner.queue.current?.leading == .symbol("battery.100.bolt"))
        #expect(owner.queue.current?.tint == .normal)
        #expect(owner.queue.current?.duration == 4)
        #expect(owner.queue.restorableCount == 0)
    }

    @Test @MainActor func timerCompletionKeepsItsFullAlertWhenAnotherTimerStarts() throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let clock = CoordinatorClock()
        var completions = 0
        let owner = ActivityCoordinator(preferences: preferences, now: { clock.date },
                                        publish: { _, _, _, _ in }, timerCompleted: { _ in completions += 1 })
        defer { owner.stop() }
        owner.start()
        try owner.timers.start(duration: 65, label: "Tea")
        #expect(owner.queue.current?.trailing == .text("1:05"))
        owner.perform(.dismissActivity)
        clock.date += 5
        owner.reconcile()
        #expect(owner.queue.current == nil)
        owner.perform(.restoreActivity)
        #expect(owner.queue.current?.trailing == .text("1:00"))
        clock.date += 60
        owner.reconcile()
        #expect(completions == 1)
        #expect(owner.queue.current?.trailing == .text("Tea done"))
        clock.date += 1
        try owner.timers.start(duration: 120, label: "Break")
        #expect(owner.queue.current?.trailing == .text("Tea done"))
        clock.date += 10
        owner.reconcile()
        #expect(owner.queue.current?.trailing == .text("1:50"))
        #expect(owner.queue.current?.priority == 110)
        try preferences.set(false, for: Preferences.timerEnabled)
        owner.refreshPreferences()
        #expect(owner.queue.current == nil)
        #expect(owner.timers.timers.count == 1)
    }

    @Test @MainActor func calendarMinuteRefreshDoesNotUndoDismissalOrKeepExpiredContent() throws {
        let domain = "org.fluxfixture.activities.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let clock = CoordinatorClock()
        let owner = ActivityCoordinator(preferences: preferences, now: { clock.date },
                                        publish: { _, _, _, _ in }, timerCompleted: { _ in })
        defer { owner.stop() }
        owner.start()
        let snapshot = AgendaSnapshot(today: clock.date, tomorrow: clock.date + 86400,
            entries: [.init(id: "fixture", title: "Private calendar canary", location: nil,
                start: clock.date + 300, end: clock.date + 900, allDay: false,
                color: .init(red: 1, green: 0, blue: 0))], truncated: false)
        owner.receive(.calendar(.ready(snapshot)))
        #expect(owner.queue.current?.kind == .calendarEvent)
        owner.perform(.dismissActivity)
        clock.date += 60
        owner.reconcile()
        #expect(owner.queue.current == nil)
        owner.perform(.restoreActivity)
        #expect(owner.queue.current?.trailing == .text("Private calendar canary · in 4m"))
        clock.date += 240
        owner.reconcile()
        #expect(owner.queue.current == nil)
        #expect(owner.queue.restorableCount == 0)
    }
}
