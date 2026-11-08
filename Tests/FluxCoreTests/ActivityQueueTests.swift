import Foundation
import Testing
@testable import FluxCore

@MainActor private final class ActivityClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

@MainActor @Test func activityKindsStayBoundedAndAnUpdateKeepsItsIdentity() throws {
    let clock = ActivityClock()
    let queue = ActivityQueue { clock.date }
    defer { queue.clear() }
    var changes = 0
    queue.onChange = { changes += 1 }
    func item(_ kind: ActivityKind, _ priority: Int, _ duration: Double? = nil) throws -> ActivityItem {
        try .init(kind: kind, leading: .symbol("battery"), trailing: .text("Fixture"), priority: priority, duration: duration)
    }
    try queue.post(item(.battery, 200))
    let first = queue.current?.id
    try queue.post(item(.battery, 200))
    #expect(queue.current?.id == first)
    #expect(changes == 1)
    try queue.post(item(.soundHUD, 300, 2))
    #expect(queue.current?.kind == .soundHUD)
    clock.date += 3
    queue.reconcile()
    #expect(queue.current?.id == first)
    for kind in ActivityKind.allCases { try queue.post(item(kind, 10)) }
    #expect(queue.count == ActivityKind.allCases.count)
}

@MainActor @Test func activityDismissRestoreDoesNotResurrectExpiredOrCompletedWork() throws {
    let clock = ActivityClock()
    let queue = ActivityQueue { clock.date }
    defer { queue.clear() }
    try queue.post(.init(kind: .battery, leading: .none, trailing: .text("Low"), priority: 200, duration: nil))
    try queue.post(.init(kind: .timer, leading: .none, trailing: .text("Timer"), priority: 250, duration: 5))
    queue.dismissCurrent()
    #expect(queue.current?.kind == .battery)
    clock.date += 6
    queue.restoreLastDismissed()
    #expect(queue.count == 1)
    queue.dismissCurrent()
    queue.remove(.battery)
    queue.restoreLastDismissed()
    #expect(queue.current == nil)
    #expect(queue.restorableCount == 0)
}

@MainActor @Test func activityCyclingRemembersTheUsersChoiceUntilItDisappears() throws {
    let queue = ActivityQueue()
    defer { queue.clear() }
    try queue.post(.init(kind: .battery, leading: .none, trailing: .none, priority: 200, duration: nil))
    try queue.post(.init(kind: .calendarEvent, leading: .none, trailing: .none, priority: 100, duration: nil))
    queue.cycle()
    #expect(queue.current?.kind == .calendarEvent)
    try queue.post(.init(kind: .soundHUD, leading: .none, trailing: .none, priority: 300, duration: nil))
    #expect(queue.current?.kind == .calendarEvent)
    queue.remove(.calendarEvent)
    #expect(queue.current?.kind == .soundHUD)
}

@MainActor @Test func producerTicksDoNotRestoreAnActivityTheUserDismissed() throws {
    let queue = ActivityQueue()
    defer { queue.clear() }
    let initial = try ActivityItem(kind: .battery, leading: .none, trailing: .text("20%"), priority: 200, duration: nil)
    queue.post(initial)
    let id = queue.current?.id
    let lower = try ActivityItem(kind: .battery, leading: .none, trailing: .text("19%"), priority: 200, duration: nil)
    #expect(queue.updateIfPresent(lower))
    #expect(queue.current?.id == id)
    queue.dismissCurrent()
    #expect(!queue.updateIfPresent(initial))
    #expect(queue.current == nil)
    #expect(queue.restorableCount == 1)
    queue.restoreLastDismissed()
    #expect(queue.current?.trailing == .text("19%"))
}
