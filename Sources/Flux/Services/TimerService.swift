import Foundation
import Combine

/// One user-started countdown timer — running, paused, or (transiently, on
/// its way to being reaped by `TimerService`'s boundary task) just finished.
///
/// Time math is intentionally all here, as plain pure functions of stored
/// values plus an explicit `at`/`after` instant — never `Date()` read
/// internally — so `--selftest` can drive every case (mid-countdown, paused,
/// overdue) deterministically, the same way `NowPlayingService.
/// currentElapsed(at:)` and `NotchActivityRouter`'s calendar-boundary math
/// are pure and clock-injected rather than reaching for the wall clock
/// themselves.
struct NotchTimer: Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Total length this timer counts down from — fixed at creation; there's
    /// no "extend a running timer" operation in this milestone.
    let duration: TimeInterval
    /// When `start()` created this timer. Combined with `accumulatedPause`
    /// (and, while paused, `pausedAt`) this is the only clock state a timer
    /// carries — no separately-tracked "remaining" field that could drift
    /// out of sync with it.
    let startedAt: Date
    /// Non-`nil` exactly while this timer is paused — the instant `pause(_:)`
    /// was called. `resume(_:)` folds the elapsed pause span into
    /// `accumulatedPause` and clears this back to `nil`.
    var pausedAt: Date?
    /// Total seconds already spent paused across every completed pause/resume
    /// cycle (NOT including the current in-flight pause, if any — that's
    /// still only implied by `pausedAt` until `resume(_:)` folds it in).
    var accumulatedPause: TimeInterval

    init(id: UUID = UUID(), label: String, duration: TimeInterval, startedAt: Date,
         pausedAt: Date? = nil, accumulatedPause: TimeInterval = 0) {
        self.id = id
        self.label = label
        self.duration = duration
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.accumulatedPause = accumulatedPause
    }

    var isPaused: Bool { pausedAt != nil }

    /// The wall-clock instant this timer will (or nominally would, if it's
    /// currently paused) finish — derived purely from `startedAt`/`duration`/
    /// `accumulatedPause`, with no dependence on "now". This is the deadline
    /// `TimerService`'s single boundary `Task` reschedules itself against
    /// (see `nextDeadline(in:after:)`), which only ever consults it for
    /// UNPAUSED timers — see that function's own doc comment for why a
    /// paused timer's `endDate` isn't a meaningful "when it finishes" answer
    /// on its own (it stops advancing the moment `pause(_:)` is called, and
    /// only starts meaning that again once `resume(_:)` folds the pause span
    /// into `accumulatedPause`).
    var endDate: Date {
        startedAt.addingTimeInterval(duration + accumulatedPause)
    }

    /// Seconds left as of `now`. While paused, the countdown is frozen at
    /// exactly what it read the instant `pause(_:)` was called — `now` is
    /// deliberately ignored in that branch (the reference instant is
    /// `pausedAt`, not `now`) — rather than continuing to drain while nobody
    /// is watching it tick, which would defeat the entire point of pausing.
    func remaining(at now: Date) -> TimeInterval {
        let reference = pausedAt ?? now
        return duration - (reference.timeIntervalSince(startedAt) - accumulatedPause)
    }

    /// `remaining(at:) <= 0` — a timer sitting exactly at zero counts as
    /// finished rather than needing to cross into negative first, so a
    /// boundary check running slightly late still catches it.
    func isFinished(at now: Date) -> Bool {
        remaining(at: now) <= 0
    }
}

/// Owns every running/paused countdown timer. Multiple timers can be live at
/// once — there is no "one timer at a time" limit anywhere in this type.
///
/// ## Completion is event-only, deliberately
/// `completions` fires when a timer's countdown reaches zero; that's the
/// entire extent of what this service does about it. It does NOT post a
/// `LiveActivity`, does NOT play a sound, and does NOT touch
/// `UNUserNotificationCenter` — every one of those is presentation/UX policy
/// that belongs to the integrator's `NotchActivityRouter` (which already owns
/// every other producer that turns a headless service's events into notch UI
/// — see that type's own doc comment), not to this service. Keeping this
/// class's surface to "here's what happened, plainly" is what lets
/// `--selftest` exercise the countdown/pause/cancel/completion machinery with
/// zero window-server, zero audio, and zero notification-center dependencies.
///
/// ## No repeating `Timer`, ever
/// Matches the M4/M5 boundary-task pattern already established by
/// `LiveActivityCenter`'s per-activity expiry and `NotchActivityRouter`'s
/// calendar-boundary scheduling: exactly ONE cancellable `Task.sleep`,
/// rearmed at `nextDeadline(after:)` on every mutation that could move that
/// deadline (`start`/`pause`/`resume`/`cancel`, and the boundary firing
/// itself) — never a `Timer.scheduledTimer` ticking every second regardless
/// of whether anything is actually due. Live countdown *display* (the
/// per-second tick a running timer's remaining-time text needs) is the
/// widget's own concern, gated on presentation — this service never ticks on
/// a wall-clock cadence at all.
@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var timers: [NotchTimer] = []

    /// Fires once per timer the instant its countdown reaches zero, carrying
    /// the (about-to-be-removed) `NotchTimer` itself — so a consumer can
    /// still read its `label` after it's gone from `timers`. See the type
    /// doc comment: this is the ONLY completion signal this service emits.
    let completions = PassthroughSubject<NotchTimer, Never>()

    /// The single scheduled boundary task — see the type doc comment's "No
    /// repeating `Timer`, ever" section. Always cancelled and (if there's a
    /// next deadline at all) replaced on every mutation, so at most one is
    /// ever in flight.
    private var boundaryTask: Task<Void, Never>?

    init() {}

    deinit {
        boundaryTask?.cancel()
    }

    /// Starts a new countdown timer and returns it. `label` is entirely the
    /// caller's concern (`TimersWidget` supplies something like "5 min" by
    /// default) — this service has no opinion about labeling.
    @discardableResult
    func start(duration: TimeInterval, label: String) -> NotchTimer {
        let timer = NotchTimer(label: label, duration: duration, startedAt: Date())
        timers.append(timer)
        rescheduleBoundary()
        return timer
    }

    /// No-op if `id` doesn't exist or is already paused — callers never need
    /// to check either condition themselves first.
    func pause(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].isPaused else { return }
        timers[index].pausedAt = Date()
        rescheduleBoundary()
    }

    /// No-op if `id` doesn't exist or isn't currently paused.
    func resume(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), let pausedAt = timers[index].pausedAt else { return }
        timers[index].accumulatedPause += Date().timeIntervalSince(pausedAt)
        timers[index].pausedAt = nil
        rescheduleBoundary()
    }

    /// No-op if `id` doesn't exist — cancelling an already-finished (and
    /// therefore already-removed) or already-cancelled timer is harmless.
    func cancel(_ id: UUID) {
        guard timers.contains(where: { $0.id == id }) else { return }
        timers.removeAll { $0.id == id }
        rescheduleBoundary()
    }

    /// Instance-facing wrapper over the pure `nextDeadline(in:after:)` core
    /// below, over this service's own live `timers`.
    func nextDeadline(after now: Date) -> Date? {
        Self.nextDeadline(in: timers, after: now)
    }

    /// The earliest still-counting-down (unpaused) timer's `endDate` — the
    /// deadline `rescheduleBoundary` arms its single `Task` against, and the
    /// same deadline the integrator's sticky `.timer` live activity (via
    /// `TimersWidget.nextDeadline`/`nearestRemainingLine`) would want to key
    /// off of. `nil` when every timer is paused, or there are no timers at
    /// all.
    ///
    /// Deliberately NOT filtered against `now` (unlike, say,
    /// `NotchActivityRouter.nextCalendarBoundary`'s `> now` filter on its own
    /// candidate boundaries) — an already-overdue deadline (the boundary task
    /// simply hasn't run yet — e.g. immediately after a system sleep/wake, or
    /// while this very function is being called from inside
    /// `handleBoundary` before the finished timer has been removed) must
    /// still be reported here, not silently skipped. Skipping it would make
    /// `rescheduleBoundary` compute no deadline at all for an overdue timer,
    /// leaving it stuck "overdue but never reaped" until some unrelated
    /// mutation happened to rearm the task. `rescheduleBoundary` is the one
    /// that clamps the resulting sleep interval to `>= 0` for a
    /// past-or-present deadline, not this function.
    static func nextDeadline(in timers: [NotchTimer], after now: Date) -> Date? {
        timers.filter { !$0.isPaused }.map(\.endDate).min()
    }

    // MARK: - Boundary task

    private func rescheduleBoundary() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard let deadline = nextDeadline(after: Date()) else { return }
        let interval = max(deadline.timeIntervalSinceNow, 0)
        boundaryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.handleBoundary()
        }
    }

    /// Reaps every unpaused timer that's actually finished as of right now,
    /// emits one `completions` event per timer reaped, then rearms the
    /// boundary for whatever's next. Guards against firing for nothing (a
    /// cancelled-and-superseded task racing its own cancellation check) by
    /// simply rearming with no completions in that case, rather than
    /// asserting — a boundary task that wakes up to find nothing actually due
    /// is a timing footgun to tolerate silently, not a bug to crash over.
    private func handleBoundary() {
        let now = Date()
        let finishedIDs = Set(timers.filter { !$0.isPaused && $0.isFinished(at: now) }.map(\.id))
        guard !finishedIDs.isEmpty else {
            rescheduleBoundary()
            return
        }
        let finished = timers.filter { finishedIDs.contains($0.id) }
        timers.removeAll { finishedIDs.contains($0.id) }
        for timer in finished { completions.send(timer) }
        rescheduleBoundary()
    }
}
