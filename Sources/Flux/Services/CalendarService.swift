import Foundation
import EventKit
import AppKit
import Combine
import OSLog

/// Shared logging point for the calendar subsystem — mirrors `shelfLog`'s/
/// `powerLog`'s file-scope-constant pattern rather than adding a new case to
/// `Log.swift`, since Calendar is a self-contained M4 subsystem the notch
/// suite owns.
let calendarLog = Logger(subsystem: "com.flux.menubar", category: "calendar")

/// A display-ready calendar event — `CalendarService`'s own model, decoupled
/// from `EKEvent` (which isn't `Sendable`/`Equatable` and is awkward to hold
/// across a `@Published` diff) the same way `NowPlayingState` decouples the
/// Now Playing widget from raw MediaRemote payloads.
struct CalendarEvent: Identifiable {
    /// `EKEvent.eventIdentifier` — falls back to a fresh UUID for the rare
    /// event that doesn't have one (per Apple's own docs, occurrence changes
    /// on some recurring/exchange events can transiently leave it nil), so
    /// this is never used as a stable cross-launch identity, only as a
    /// same-session `Identifiable` key for SwiftUI's `ForEach`.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The owning calendar's tint, for the colored dot in the agenda list.
    /// `nil` only if the event's calendar itself has somehow gone away
    /// between the fetch and now.
    let calendarColor: NSColor?
    let location: String?
}

extension CalendarEvent: Equatable {
    /// Manual conformance: `NSColor` doesn't itself conform to `Equatable`,
    /// so this can't be synthesized. Two colors compare via `NSObject.isEqual`
    /// (real component-wise equality for the plain sRGB colors EventKit hands
    /// back), not identity.
    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.start == rhs.start &&
        lhs.end == rhs.end &&
        lhs.isAllDay == rhs.isAllDay &&
        lhs.location == rhs.location &&
        ((lhs.calendarColor == nil && rhs.calendarColor == nil) ||
         (lhs.calendarColor?.isEqual(rhs.calendarColor) ?? false))
    }
}

/// Headless data layer behind the notch's Calendar widget (and the
/// event-soon live activity `NotchActivityRouter` posts from the same
/// `upcoming` list): owns the one `EKEventStore`, fetches a short look-ahead
/// window, and refreshes on `.EKEventStoreChanged` — never on a repeating
/// timer, matching the notch suite's zero-idle-timer perf contract.
///
/// ## Two independent consumers, one shared lifecycle
/// Unlike `NowPlayingService` (one widget, one caller of `setActive`), this
/// service has two independent owners: `CalendarWidget`'s own
/// `willPresent()`/`didDismiss()` (the widget being open), and
/// `NotchActivityRouter` (the event-soon activity toggle, which needs the
/// data flowing even while the widget itself is closed). Both call the same
/// plain, idempotent `start()`/`stop()` (mirroring `PowerMonitor`'s
/// boolean-guarded shape rather than a reference count) — what keeps that
/// safe with two callers isn't anything in this type, but a rule the router
/// itself enforces: it only ever calls `stop()` after confirming (via an
/// injected `isCalendarWidgetPresented` closure) that the widget isn't
/// currently the one relying on the service being up. See
/// `NotchActivityRouter.applyMonitorState`'s calendar branch for exactly
/// where that check lives.
@MainActor
final class CalendarService: ObservableObject {
    /// Newest-first is meaningless here (these are all in the future) — kept
    /// sorted by `start` ascending, capped at 10, so every consumer (the
    /// widget's agenda, the event-soon activity, `nextEventLine`) can just
    /// take the list as-is.
    @Published private(set) var upcoming: [CalendarEvent] = []

    private let eventStore: EKEventStore
    private var isStarted = false
    private var cancellables = Set<AnyCancellable>()

    init(eventStore: EKEventStore? = nil) {
        // `?? EKEventStore()` constructed here in the body — mirroring
        // `NowPlayingService`'s sources and `PowerMonitor`/`BluetoothMonitor`
        // being handed to `NotchActivityRouter` the same way — for
        // consistency with this codebase's `@MainActor`-isolated-type
        // convention, even though `EKEventStore` itself isn't one.
        self.eventStore = eventStore ?? EKEventStore()
    }

    // MARK: - Lifecycle

    /// Starts observing `.EKEventStoreChanged` and takes an immediate first
    /// fetch. No-op if already started (see the type's doc comment on why
    /// two independent callers can both call this freely). Silently produces
    /// an empty `upcoming` — not an error — when permission isn't (yet, or
    /// no longer) granted; `PermissionCenter` is the single source of truth
    /// for *why*, which this type deliberately doesn't duplicate.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    /// Tears down the change observation. No-op if already stopped.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancellables.removeAll()
    }

    private func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcoming = []
            return
        }
        let fetched = Self.fetchUpcoming(from: eventStore, now: Date())
        calendarLog.debug("Calendar refresh: \(fetched.count, privacy: .public) upcoming event(s)")
        upcoming = fetched
    }

    // MARK: - Fetch (impure — talks to EventKit)

    /// Window is now → end of tomorrow (i.e. the start of the day after
    /// tomorrow, exclusive), sorted ascending, capped at 10, with the current
    /// user's own declined events filtered out — cheap since EventKit already
    /// hands back each event's `attendees` in the same fetch, no extra query
    /// per event.
    private static func fetchUpcoming(from store: EKEventStore, now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: 2, to: startOfToday) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: windowEnd, calendars: nil)
        // `events(matching:)` returns a plain (non-optional) array — an empty
        // result just means nothing matched, not "unknown."
        let events = store.events(matching: predicate)
        return events
            .filter { !isDeclinedByCurrentUser($0) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map(makeCalendarEvent)
    }

    private static func isDeclinedByCurrentUser(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    private static func makeCalendarEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarColor: event.calendar?.color,
            location: event.location?.isEmpty == false ? event.location : nil
        )
    }

    // MARK: - Pure display helpers (testable without a real EKEventStore)

    /// The compact "in 25 min" notch-strip line for whatever's next — the
    /// earliest event that hasn't ended yet. `nil` when nothing qualifies
    /// (an empty list, or every event has already ended).
    static func nextEventLine(events: [CalendarEvent], now: Date) -> String? {
        guard let next = events.filter({ $0.end > now }).min(by: { $0.start < $1.start }) else { return nil }
        guard next.start > now else { return "\(next.title) now" }

        let minutes = Int((next.start.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { return "\(next.title) now" }
        if minutes < 60 { return "\(next.title) in \(minutes)m" }
        let hours = Int((next.start.timeIntervalSince(now) / 3600).rounded())
        return "\(next.title) in \(hours)h"
    }

    /// The Calendar widget's Today/Tomorrow agenda sections. Anchored purely
    /// on each event's `start` (including all-day events, whose `start` is
    /// local midnight) against `calendar`'s notion of day boundaries — an
    /// event starting anywhere outside [today's midnight, day-after-
    /// tomorrow's midnight) appears in neither section (it's outside the
    /// fetch window in practice, but this stays correct even if fed a wider
    /// list directly, as the self-test does).
    struct DayGroups: Equatable {
        let today: [CalendarEvent]
        let tomorrow: [CalendarEvent]
    }

    static func groupByDay(events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> DayGroups {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow)
        else { return DayGroups(today: [], tomorrow: []) }

        var today: [CalendarEvent] = []
        var tomorrow: [CalendarEvent] = []
        for event in events {
            if event.start >= startOfToday && event.start < startOfTomorrow {
                today.append(event)
            } else if event.start >= startOfTomorrow && event.start < startOfDayAfterTomorrow {
                tomorrow.append(event)
            }
        }
        return DayGroups(today: today, tomorrow: tomorrow)
    }
}
