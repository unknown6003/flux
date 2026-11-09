import Foundation
import Testing
import FluxPlatform
@testable import FluxApplication

struct DuoCalendarPolicyTests {
    @Test func relevantEventsAndBoundariesKeepTheSavedEveningRule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
        let tomorrow = today.addingTimeInterval(86_400)
        func event(_ id: String, hour: Double, duration: Double = 1) -> AgendaEntry {
            .init(id: id, title: id, location: nil, start: today.addingTimeInterval(hour * 3600),
                end: today.addingTimeInterval((hour + duration) * 3600), allDay: false,
                color: .init(red: 0, green: 0, blue: 0))
        }
        let snapshot = AgendaSnapshot(today: today, tomorrow: tomorrow,
            entries: [event("ended", hour: 12), event("morning", hour: 33), event("noon", hour: 36)], truncated: false)
        let before = today.addingTimeInterval(19 * 3600)
        let evening = today.addingTimeInterval(20 * 3600)
        #expect(!DuoCalendarPolicy.hasEvents(snapshot, at: before, calendar: calendar))
        #expect(DuoCalendarPolicy.nextBoundary(snapshot, after: before, calendar: calendar) == evening)
        #expect(DuoCalendarPolicy.events(snapshot, at: evening, calendar: calendar).map(\.id) == ["morning"])
        #expect(!DuoCalendarPolicy.hasEvents(snapshot, at: tomorrow, calendar: calendar))
        let live = AgendaSnapshot(today: today, tomorrow: tomorrow,
            entries: [event("current", hour: 19, duration: 2)], truncated: false)
        #expect(DuoCalendarPolicy.hasEvents(live, at: evening, calendar: calendar))
        #expect(DuoCalendarPolicy.nextBoundary(live, after: evening, calendar: calendar) == today.addingTimeInterval(21 * 3600))
    }
}
