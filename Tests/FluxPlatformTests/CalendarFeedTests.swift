import EventKit
import Foundation
import Testing
@testable import FluxPlatform

private actor GatedAgendaReader: AgendaReading {
    private(set) var calls = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var reads: [CheckedContinuation<AgendaReadResult, Never>] = []

    func read(at now: Date) async -> AgendaReadResult {
        calls += 1
        let ready = waiting.filter { $0.0 <= calls }
        waiting.removeAll { $0.0 <= calls }
        return await withCheckedContinuation { continuation in
            reads.append(continuation)
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }

    func finish(_ result: AgendaReadResult) {
        reads.removeFirst().resume(returning: result)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func calendarChangesCoalesceWithoutOverlappingDatabaseReads() async {
    let reader = GatedAgendaReader()
    let center = NotificationCenter()
    let (stream, continuation) = AsyncStream.makeStream(of: AgendaReadResult.self)
    let feed = CalendarFeed(reader: reader, center: center) { continuation.yield($0) }
    var results = stream.makeAsyncIterator()
    await reader.waitForCalls(1)
    for _ in 0..<10 { feed.refresh() }
    #expect(await reader.calls == 1)
    await reader.finish(.needsPermission)
    #expect(await results.next() == .needsPermission)
    await reader.waitForCalls(2)
    #expect(await reader.calls == 2)
    await reader.finish(.unavailable)
    #expect(await results.next() == .unavailable)
    center.post(name: .EKEventStoreChanged, object: nil)
    await reader.waitForCalls(3)
    await reader.finish(.needsPermission)
    #expect(await results.next() == .needsPermission)
    center.post(name: .NSSystemClockDidChange, object: nil)
    await reader.waitForCalls(4)
    await reader.finish(.unavailable)
    #expect(await results.next() == .unavailable)
    center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    await reader.waitForCalls(5)
    await reader.finish(.needsPermission)
    #expect(await results.next() == .needsPermission)
    feed.stop()
    continuation.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func stoppingCalendarReleasesFeedDuringAnUnfinishedDatabaseRead() async {
    let reader = GatedAgendaReader()
    let center = NotificationCenter()
    var callbacks = 0
    var feed: CalendarFeed? = CalendarFeed(reader: reader, center: center) { _ in callbacks += 1 }
    weak var released = feed
    await reader.waitForCalls(1)
    feed?.stop()
    feed = nil
    #expect(released == nil)
    await reader.finish(.unavailable)
    center.post(name: .EKEventStoreChanged, object: nil)
    // The observer and callback are gone. A late database result cannot keep the feed alive.
    #expect(released == nil)
    #expect(callbacks == 0)
    #expect(await reader.calls == 1)
}
