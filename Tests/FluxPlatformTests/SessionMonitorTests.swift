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
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    monitor.stop()
    await Task.yield()
    #expect(monitor.phase == .locked)
    #expect(environmentChanges == 1)
}
