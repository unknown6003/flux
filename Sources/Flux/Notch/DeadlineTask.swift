import Foundation

/// The shared shape behind every "wake up once, at some computed instant,
/// and do one thing" scheduler in the notch suite — `TimerService.
/// rescheduleBoundary`, `NotchActivityRouter`'s calendar-boundary and
/// timer-refresh schedulers, and `LiveActivityCenter`'s per-activity expiry
/// all independently hand-rolled the identical cancel-the-old-task /
/// (if there's a next deadline) sleep-until-it / re-invoke idiom before this
/// was pulled out into one place. Exactly ONE `Task` in flight at a time per
/// `DeadlineTask` instance — matching the notch suite's no-repeating-`Timer`
/// perf contract everywhere it's used: a deadline is either rescheduled
/// (cancelling whatever was pending) or left cancelled with nothing pending,
/// never ticking on its own.
@MainActor
final class DeadlineTask {
    private var task: Task<Void, Never>?

    init() {}

    deinit {
        task?.cancel()
    }

    /// Cancels whatever's currently scheduled, then — if `date` is non-`nil`
    /// — arms `action` to run at that instant. `date` may be in the past
    /// (an already-overdue deadline some callers deliberately still report
    /// rather than silently skip — see e.g. `TimerService.nextDeadline`'s own
    /// doc comment on why); the sleep interval is clamped to `>= 0` in that
    /// case rather than passing a negative duration to `Task.sleep`. Passing
    /// `nil` cancels with nothing rearmed, matching every call site's own
    /// "no next deadline" case (nothing left to schedule against).
    func reschedule(to date: Date?, action: @MainActor @escaping () -> Void) {
        task?.cancel()
        task = nil
        guard let date else { return }
        let interval = max(date.timeIntervalSinceNow, 0)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard self != nil, !Task.isCancelled else { return }
            action()
        }
    }

    /// Cancels whatever's currently scheduled with nothing rearmed — the
    /// bare "tear this down" half of `reschedule(to:action:)`, for callers
    /// that need to cancel without in the same breath deciding a
    /// replacement (e.g. re-evaluating gating before it's known whether
    /// there's a new deadline at all).
    func cancel() {
        task?.cancel()
        task = nil
    }
}
