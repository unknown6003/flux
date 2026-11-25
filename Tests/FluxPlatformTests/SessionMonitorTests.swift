import AppKit
import Testing
import FluxCore
@testable import FluxPlatform

@MainActor @Test func sessionDictionaryRecognizesOmittedUnlockedKeyAndRefusesMalformedValues() {
    let console = kCGSessionOnConsoleKey as String
    #expect(SessionMonitor.phase(from: [console: true]) == .unlocked)
    #expect(SessionMonitor.phase(from: [console: true, "CGSSessionScreenIsLocked": true]) == .locked)
    #expect(SessionMonitor.phase(from: [console: false, "CGSSessionScreenIsLocked": false]) == .locked)
    #expect(SessionMonitor.phase(from: [console: true, "CGSSessionScreenIsLocked": "false"]) == .locked)
    #expect(SessionMonitor.phase(from: nil) == .locked)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sessionMonitorPausesOnSleepAndResignAndDropsQueuedEventsAfterStop() async {
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    var systemPhase = SessionPhase.unlocked
    var phases: [SessionPhase] = []
    var environmentChanges = 0
    let monitor = SessionMonitor(workspace: workspace, application: application, distributed: nil,
                                 readPhase: { systemPhase }, onPhase: { phases.append($0) },
                                 onEnvironmentChange: { environmentChanges += 1 })
    #expect(monitor.phase == .unlocked)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .sleeping)
    systemPhase = .locked
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .locked)
    systemPhase = .unlocked
    monitor.refresh()
    #expect(monitor.phase == .unlocked)
    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .locked)
    #expect(phases == [.sleeping, .locked, .unlocked, .locked])
    #expect(environmentChanges == 1)
    application.post(name: .NSSystemClockDidChange, object: nil)
    await Task.yield()
    #expect(environmentChanges == 2)
    application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .unlocked)
    #expect(environmentChanges == 3)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    monitor.stop()
    await Task.yield()
    #expect(monitor.phase == .unlocked)
    #expect(environmentChanges == 3)
    #expect(!monitor.hasActiveReconciliationTasks)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sessionMonitorRecoversWhenScreenUnlockedArrivesBeforeSessionDictionaryUpdates() async throws {
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    var systemPhase = SessionPhase.locked
    var readsAfterUnlock = 0
    var phases: [SessionPhase] = []
    var environmentChanges = 0
    let monitor = SessionMonitor(
        workspace: workspace,
        application: application,
        distributed: nil,
        readPhase: {
            if readsAfterUnlock > 0 {
                readsAfterUnlock -= 1
                return .locked
            }
            return systemPhase
        },
        unlockRecheckDelays: [.milliseconds(10), .milliseconds(15), .milliseconds(25)],
        lockedReconcileInterval: .seconds(30),
        onPhase: { phases.append($0) },
        onEnvironmentChange: { environmentChanges += 1 }
    )
    defer { monitor.stop() }
    #expect(monitor.phase == .locked)

    // Simulate macOS delivering com.apple.screenIsUnlocked ~10ms before
    // CGSessionCopyCurrentDictionary() clears CGSSessionScreenIsLocked.
    readsAfterUnlock = 2
    systemPhase = .unlocked
    monitor.handleScreenUnlockedNotification()
    #expect(monitor.phase == .locked)
    #expect(environmentChanges == 1)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while monitor.phase != .unlocked, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(monitor.phase == .unlocked)
    #expect(phases == [.unlocked])
    #expect(environmentChanges == 2)
    #expect(!monitor.hasActiveReconciliationTasks)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sessionMonitorReconcilesMissedUnlockOnlyWhileLockedAndStaysIdleWhenUnlockedOrSleeping() async throws {
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    var systemPhase = SessionPhase.unlocked
    var phases: [SessionPhase] = []
    var environmentChanges = 0
    let monitor = SessionMonitor(
        workspace: workspace,
        application: application,
        distributed: nil,
        readPhase: { systemPhase },
        unlockRecheckDelays: [.milliseconds(10)],
        lockedReconcileInterval: .milliseconds(25),
        onPhase: { phases.append($0) },
        onEnvironmentChange: { environmentChanges += 1 }
    )
    defer { monitor.stop() }
    #expect(monitor.phase == .unlocked)
    #expect(!monitor.hasActiveReconciliationTasks)

    // Lock, then flip systemPhase to .unlocked without delivering screenIsUnlocked
    // (covers dropped distributed notification or out-of-order sessionDidResignActive).
    monitor.handleScreenLockedNotification()
    #expect(monitor.phase == .locked)
    #expect(monitor.hasActiveReconciliationTasks)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while monitor.phase != .unlocked, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(monitor.phase == .unlocked)
    #expect(phases == [.locked, .unlocked])
    #expect(environmentChanges == 1)
    #expect(!monitor.hasActiveReconciliationTasks)

    // Sleeping must cancel any locked reconciliation task.
    systemPhase = .locked
    monitor.handleScreenLockedNotification()
    #expect(monitor.phase == .locked)
    #expect(monitor.hasActiveReconciliationTasks)
    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .sleeping)
    #expect(!monitor.hasActiveReconciliationTasks)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sessionMonitorRefusesSpoofedUnlockWhileSessionDictionaryRemainsLocked() async throws {
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    var phases: [SessionPhase] = []
    let monitor = SessionMonitor(
        workspace: workspace,
        application: application,
        distributed: nil,
        readPhase: { .locked },
        unlockRecheckDelays: [.milliseconds(10), .milliseconds(10)],
        lockedReconcileInterval: .seconds(30),
        onPhase: { phases.append($0) },
        onEnvironmentChange: {}
    )
    defer { monitor.stop() }
    #expect(monitor.phase == .locked)

    monitor.handleScreenUnlockedNotification()
    try await Task.sleep(for: .milliseconds(60))
    #expect(monitor.phase == .locked)
    #expect(phases.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sessionMonitorRecoversOnWorkspaceSessionActiveRaceAndIgnoresSpaceChangeDuringLockLag() async throws {
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    var systemPhase = SessionPhase.locked
    var lagReads = 0
    var phases: [SessionPhase] = []
    let monitor = SessionMonitor(
        workspace: workspace,
        application: application,
        distributed: nil,
        readPhase: {
            if lagReads > 0 {
                lagReads -= 1
                return .locked
            }
            return systemPhase
        },
        onPhase: { phases.append($0) },
        onEnvironmentChange: {}
    )
    defer { monitor.stop() }
    #expect(monitor.phase == .locked)

    // sessionDidBecomeActiveNotification arrives 1 read before CGSession clears.
    lagReads = 1
    systemPhase = .unlocked
    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while monitor.phase != .unlocked, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(monitor.phase == .unlocked)
    #expect(phases == [.unlocked])

    // Re-lock while CGSession still transiently reports .unlocked; space/display
    // notifications during the lock transition must not prematurely unlock.
    monitor.handleScreenLockedNotification()
    #expect(monitor.phase == .locked)
    workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    await Task.yield()
    #expect(monitor.phase == .locked)
    #expect(phases == [.unlocked, .locked])
}
