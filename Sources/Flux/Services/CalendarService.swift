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
    /// A per-*occurrence* identity: `EKEvent.eventIdentifier` — falling back
    /// to a fresh UUID for the rare event that doesn't have one (per Apple's
    /// own docs, occurrence changes on some recurring/exchange events can
    /// transiently leave it nil) — combined with the occurrence's own
    /// `startDate`. Every occurrence of a *recurring* event shares the exact
    /// same `eventIdentifier`, so without the start-date suffix two
    /// occurrences pulled into the same `upcoming` window (e.g. a daily
    /// standup appearing both "today" and "tomorrow") would collide on `id` —
    /// breaking `ForEach`'s per-row identity (SwiftUI would conflate the two
    /// rows into one) and any future per-id de-dup. Still never used as a
    /// stable cross-launch identity, only as a same-session `Identifiable`
    /// key for SwiftUI's `ForEach`.
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
/// window, and refreshes on `.EKEventStoreChanged` (debounced — see
/// `start()`) — never on a repeating timer, matching the notch suite's
/// zero-idle-timer perf contract. A second, independent cancellable task (see
/// `scheduleMidnightRollover`) re-fetches once at the next local midnight, so
/// the "now → end of tomorrow" window itself stays correct across a midnight
/// rollover even with no `EKEventStoreChanged` in sight.
///
/// ## Lifecycle ownership: `NotchActivityRouter`, exclusively
/// `start()`/`stop()` are plain, idempotent booleans (mirroring
/// `PowerMonitor`'s shape) — but unlike `NowPlayingService` (whose only
/// caller of `setActive` is its one widget), this service used to have TWO
/// independent callers (`CalendarWidget` and `NotchActivityRouter`), which is
/// exactly the shape that let a code-review-flagged bug slip through: a
/// permission grant while the widget was open never started the service
/// (neither owner's condition was individually true at that instant), and
/// the router's own bespoke "is the widget still open?" closure needed
/// constant upkeep to avoid the two owners fighting over `stop()`.
///
/// The fix folded ownership into ONE place: `NotchActivityRouter` is now the
/// sole caller of `start()`/`stop()`, deriving whether the service should run
/// from every input that matters — calendar permission, notch presentation,
/// whether the Calendar widget is the one currently expanded, and the
/// event-soon activity toggle — in one pure function,
/// `NotchActivityRouter.calendarServiceShouldRun`. `CalendarWidget` itself
/// only refreshes the permission status on `willPresent()`; it does not
/// start or stop this service at all anymore.
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
    /// The single deadline task that re-fetches at the next local midnight —
    /// see `scheduleMidnightRollover`'s doc comment. Mirrors
    /// `NotchActivityRouter.calendarThresholdTask`'s single-cancellable-task
    /// shape: no repeating timer.
    private var midnightRolloverTask: Task<Void, Never>?

    init(eventStore: EKEventStore? = nil) {
        // `?? EKEventStore()` constructed here in the body — mirroring
        // `NowPlayingService`'s sources and `PowerMonitor`/`BluetoothMonitor`
        // being handed to `NotchActivityRouter` the same way — for
        // consistency with this codebase's `@MainActor`-isolated-type
        // convention, even though `EKEventStore` itself isn't one.
        self.eventStore = eventStore ?? EKEventStore()
    }

    deinit {
        midnightRolloverTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts observing `.EKEventStoreChanged` and takes an immediate first
    /// fetch, then arms the midnight-rollover task. No-op if already started
    /// (see the type's doc comment on lifecycle ownership).
    /// `.EKEventStoreChanged` is debounced 300ms on the main run loop before
    /// triggering a refetch — EventKit can fire a burst of these in a row
    /// during a sync storm (e.g. an Exchange/iCloud sync landing many changes
    /// at once), and there's no reason to hit the store once per notification
    /// when settling briefly and fetching once is exactly as correct.
    /// Silently produces an empty `upcoming` — not an error — when permission
    /// isn't (yet, or no longer) granted; `PermissionCenter` is the single
    /// source of truth for *why*, which this type deliberately doesn't
    /// duplicate.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
        scheduleMidnightRollover()
    }

    /// Tears down the change observation and the midnight-rollover task.
    /// No-op if already stopped.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancellables.removeAll()
        midnightRolloverTask?.cancel()
        midnightRolloverTask = nil
    }

    /// No repeating timer: the rolling "now → end of tomorrow" fetch window
    /// (see `fetchUpcoming`) is only ever recomputed when something calls
    /// `refresh()` — an `.EKEventStoreChanged` notification, or this task.
    /// Without this, an app left running across midnight would keep showing
    /// yesterday's window (today's events sliding into what should now be
    /// "yesterday," tomorrow's into today's slot) until the calendar store
    /// happened to fire a change notification for an unrelated reason.
    /// Cancelled/replaced on every call (including by itself, once its
    /// deadline fires and it reschedules for the *next* midnight) — the same
    /// single-cancellable-deadline-task pattern as
    /// `NotchActivityRouter.scheduleNextCalendarBoundary`.
    private func scheduleMidnightRollover(now: Date = Date(), calendar: Calendar = .current) {
        midnightRolloverTask?.cancel()
        guard let nextMidnight = Self.nextMidnight(after: now, calendar: calendar) else {
            midnightRolloverTask = nil
            return
        }
        midnightRolloverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(nextMidnight.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.scheduleMidnightRollover()
        }
    }

    /// The start of the day after `date`'s own day — pure and testable
    /// without a real clock/timer. `nil` only in the essentially-impossible
    /// case `Calendar.date(byAdding:to:)` itself fails.
    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday)
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
            id: occurrenceID(eventIdentifier: event.eventIdentifier, start: event.startDate),
            title: event.title ?? "Untitled Event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarColor: event.calendar?.color,
            location: event.location?.isEmpty == false ? event.location : nil
        )
    }

    /// Every occurrence of a recurring event shares one `eventIdentifier` —
    /// appending the occurrence's own `start` (as a raw interval, not a
    /// formatted string, so this never depends on locale/timezone) is what
    /// keeps `CalendarEvent.id` unique per-occurrence. See `CalendarEvent.id`'s
    /// own doc comment for why a collision here would matter. Split out from
    /// `makeCalendarEvent` (which is otherwise impure, taking a real `EKEvent`)
    /// so this specific piece — the part a code review actually needs to
    /// verify — is a plain, pure function `--selftest` can exercise directly.
    static func occurrenceID(eventIdentifier: String?, start: Date) -> String {
        let base = eventIdentifier ?? UUID().uuidString
        return "\(base)#\(start.timeIntervalSinceReferenceDate)"
    }

    // MARK: - Pure display helpers (testable without a real EKEventStore)

    /// The shared "<title> in Nm" / "<title> in Nh" / "<title> now" wording —
    /// the ONE place any relative-start phrase gets built, so it only has to
    /// be gotten right once. Both `nextEventLine` (below) and
    /// `NotchActivityRouter.calendarEventSoonActivity` (the event-soon live
    /// activity's "in Nm" trailing text) call this rather than each
    /// re-deriving their own minutes/hours math — a prior code review flagged
    /// the router's own inline copy as duplicated phrasing that had drifted
    /// slightly from this function (always "in Nm", even at 0 minutes, where
    /// this one already says "now").
    static func relativeStartPhrase(title: String, start: Date, now: Date) -> String {
        guard start > now else { return "\(title) now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { return "\(title) now" }
        if minutes < 60 { return "\(title) in \(minutes)m" }
        let hours = Int((start.timeIntervalSince(now) / 3600).rounded())
        return "\(title) in \(hours)h"
    }

    /// The compact "in 25 min" notch-strip line for whatever's next — the
    /// earliest event that hasn't ended yet. `nil` when nothing qualifies
    /// (an empty list, or every event has already ended).
    static func nextEventLine(events: [CalendarEvent], now: Date) -> String? {
        guard let next = events.filter({ $0.end > now }).min(by: { $0.start < $1.start }) else { return nil }
        return relativeStartPhrase(title: next.title, start: next.start, now: now)
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
