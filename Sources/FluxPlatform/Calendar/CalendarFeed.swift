import EventKit
import Foundation
import FluxCore

public struct AgendaColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
}

/// Calendar content stays in the local widget. No telemetry accepts this type.
public struct AgendaEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let location: String?
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let color: AgendaColor
    public init(id: String, title: String, location: String?, start: Date, end: Date, allDay: Bool, color: AgendaColor) {
        self.id = id; self.title = title; self.location = location
        self.start = start; self.end = end; self.allDay = allDay; self.color = color
    }
}

public struct AgendaSnapshot: Equatable, Sendable {
    public let today: Date
    public let tomorrow: Date
    public let entries: [AgendaEntry]
    public let truncated: Bool
    public init(today: Date, tomorrow: Date, entries: [AgendaEntry], truncated: Bool) {
        self.today = today; self.tomorrow = tomorrow; self.entries = entries; self.truncated = truncated
    }
}

public enum AgendaReadResult: Equatable, Sendable {
    case ready(AgendaSnapshot)
    case needsPermission
    case unavailable
}

public protocol AgendaReading: Sendable {
    func read(at now: Date) async -> AgendaReadResult
}

/// EventKit's synchronous fetch runs on this actor. Construction makes no
/// EKEventStore, and a missing full-access grant never triggers a fetch or prompt.
public actor EventKitAgendaReader: AgendaReading {
    private var store: EKEventStore?
    public init() {}

    public func read(at now: Date) -> AgendaReadResult {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            store = nil
            return .needsPermission
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let end = calendar.date(byAdding: .day, value: 2, to: today) else { return .unavailable }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !Task.isCancelled,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .needsPermission }
        let entries = events.prefix(512).map { event in
            let components = event.calendar.cgColor?.components ?? []
            let color: AgendaColor
            if components.count >= 3 {
                color = .init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
            } else {
                let gray = Double(components.first ?? 0.5)
                color = .init(red: gray, green: gray, blue: gray)
            }
            return AgendaEntry(
                id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "@" + String(event.startDate.timeIntervalSinceReferenceDate),
                title: String((event.title ?? "").prefix(2000)),
                location: event.location.map { String($0.prefix(2000)) },
                start: event.startDate, end: event.endDate, allDay: event.isAllDay, color: color)
        }
        return .ready(.init(today: today, tomorrow: tomorrow, entries: entries, truncated: events.count > 512))
    }
}

/// Refetches on database changes and midnight. It has no interval poll.
/// The app can also call refresh after wake, a timezone change or permission recovery.
@MainActor public final class CalendarFeed: FeatureServiceHandle {
    public var onChange: ((AgendaReadResult) -> Void)?
    private let reader: any AgendaReading
    private var observation: NotificationObservation?
    private var readTask: Task<Void, Never>?
    private var midnight: Task<Void, Never>?
    private var active = true
    private var generation: UInt64 = 0
    private var needsAnotherRead = false

    public init(reader: any AgendaReading = EventKitAgendaReader(),
                center: NotificationCenter = .default,
                onChange: @escaping (AgendaReadResult) -> Void) {
        self.reader = reader
        self.onChange = onChange
        observation = NotificationObservation(center: center, name: .EKEventStoreChanged) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    deinit {
        readTask?.cancel()
        midnight?.cancel()
    }

    public func refresh() {
        guard active else { return }
        guard readTask == nil else {
            needsAnotherRead = true
            return
        }
        armMidnight()
        let token = generation
        let reader = self.reader
        readTask = Task { @MainActor [weak self] in
            let result = await reader.read(at: Date())
            guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
            self.readTask = nil
            self.onChange?(result)
            if self.needsAnotherRead {
                self.needsAnotherRead = false
                self.refresh()
            }
        }
    }

    public func stop() {
        active = false
        generation &+= 1
        onChange = nil
        observation = nil
        readTask?.cancel()
        readTask = nil
        midnight?.cancel()
        midnight = nil
        needsAnotherRead = false
    }

    private func armMidnight() {
        midnight?.cancel()
        guard active else { return }
        let now = Date()
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        midnight = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now)))) }
            catch { return }
            guard let self, self.active else { return }
            self.refresh()
            self.armMidnight()
        }
    }
}
