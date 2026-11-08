import Foundation
import Testing
@testable import FluxCore

@Test @MainActor func countdownCompletesOnceAfterWakeAndCannotBePausedOverdue() throws {
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
    let countdowns = Countdowns(now: { now })
    var completed: [UUID] = []
    countdowns.onCompletion = { completed.append($0.id) }
    let first = try countdowns.start(duration: 60, label: "1 min")
    let second = try countdowns.start(duration: 300, label: "5 min")
    now.addTimeInterval(120)
    countdowns.pause(first)
    #expect(completed == [first])
    #expect(countdowns.timers.map(\.id) == [second])
    countdowns.reconcile()
    #expect(completed == [first])
    now.addTimeInterval(1000)
    countdowns.reconcile()
    #expect(completed == [first, second])
    #expect(countdowns.timers.isEmpty)
}

@Test @MainActor func pausedCountdownKeepsItsRemainingTimeAndCancelDoesNotComplete() throws {
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
    let countdowns = Countdowns(now: { now })
    var completions = 0
    countdowns.onCompletion = { _ in completions += 1 }
    let id = try countdowns.start(duration: 300, label: "5 min")
    now.addTimeInterval(40)
    countdowns.pause(id)
    now.addTimeInterval(1000)
    countdowns.reconcile()
    #expect(countdowns.timers.first?.remaining(at: now) == 260)
    countdowns.resume(id)
    now.addTimeInterval(200)
    #expect(countdowns.timers.first?.remaining(at: now) == 60)
    countdowns.cancel(id)
    #expect(countdowns.timers.isEmpty)
    #expect(completions == 0)
}

@Test @MainActor func invalidOrExcessiveTimersDoNotAllocatePendingWork() throws {
    let countdowns = Countdowns()
    for duration in [Double.nan, .infinity, -1, 0, 8 * 24 * 60 * 60] {
        #expect(throws: CountdownError.self) { try countdowns.start(duration: duration, label: "Invalid") }
    }
    #expect(countdowns.timers.isEmpty)
    for _ in 0..<64 { try countdowns.start(duration: 3600, label: "Timer") }
    #expect(throws: CountdownError.self) { try countdowns.start(duration: 3600, label: "Excess") }
    #expect(countdowns.timers.count == 64)
    countdowns.cancelAll()
    #expect(countdowns.timers.isEmpty)
}
