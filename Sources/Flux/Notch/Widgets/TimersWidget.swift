import SwiftUI
import Combine
import Foundation

/// Wraps `TimerService` as a `NotchWidget`: quick-start presets plus a custom
/// minutes stepper in the expanded panel, and a live list of every running/
/// paused timer with pause/resume/cancel controls. Owns no timer state of its
/// own — `TimerService` is the single source of truth; this class only
/// adapts it to the `NotchWidget` surface and exposes the couple of pure
/// helpers (`nextDeadline`/`nearestRemainingLine`) the integrator's
/// `NotchActivityRouter` needs to drive a sticky `.timer` live-activity wing,
/// matching how `CalendarWidget`/`NowPlayingWidget` expose their own services
/// directly rather than duplicating router logic here.
@MainActor
final class TimersWidget: NotchWidget {
    let id: WidgetID = .timers

    /// Settings-driven; set by the wiring agent's Combine sink from whatever
    /// settings key gates this widget. `NotchWidgetRegistry` reads this every
    /// time it computes `enabledWidgets`.
    var isEnabled: Bool

    let service: TimerService

    init(service: TimerService, isEnabled: Bool = true) {
        self.service = service
        self.isEnabled = isEnabled
    }

    // MARK: - NotchWidget

    func makeExpandedView() -> AnyView {
        AnyView(TimersExpandedView(service: service))
    }

    /// No compact/collapsed-strip presence — like `ShelfWidget`/
    /// `CalendarWidget`, this widget only shows once expanded. The one
    /// collapsed-notch signal a running timer has (an ambient countdown wing)
    /// is the integrator's own sticky `.timer` `LiveActivity`, driven by
    /// `nextDeadline`/`nearestRemainingLine` below — it exists independently
    /// of whether this widget itself is even the one currently expanded.
    func makeCompactView() -> AnyView? { nil }

    /// Nothing to start/stop here. `TimerService` is entirely event-driven —
    /// a single cancellable boundary `Task` rearmed on every mutation (see
    /// its own doc comment) — not something with a "run only while visible"
    /// lifecycle the way `NowPlayingService`/`CalendarService` have. The
    /// running list's per-second countdown tick lives inside
    /// `TimersExpandedView` itself and gates on being both presented
    /// (structurally true — that view doesn't exist otherwise) and non-empty,
    /// so there's nothing left for `willPresent`/`didDismiss` to arm or
    /// disarm.
    func willPresent() {}
    func didDismiss() {}

    // MARK: - Live-activity support (consumed by the integrator's router)

    /// Forwards to `TimerService.nextDeadline` — the earliest still-counting-
    /// down timer's end, i.e. exactly the deadline a sticky `.timer` live
    /// activity (or its own expiry) would want to key off.
    func nextDeadline(after now: Date) -> Date? {
        service.nextDeadline(after: now)
    }

    /// The soonest-to-finish running (unpaused) timer's countdown, formatted
    /// by `formatAmbientRemaining` — what a sticky `.timer` `LiveActivity`'s
    /// trailing text (`.text(...)`) should show. `nil` when no timer is
    /// currently counting down (none exist, or every one of them is paused).
    func nearestRemainingLine(at now: Date) -> String? {
        Self.nearestRemainingLine(timers: service.timers, at: now)
    }

    /// Pure core behind `nearestRemainingLine(at:)`, over a plain `[NotchTimer]`
    /// rather than a live `service` — so `--selftest` can drive every
    /// combination of timers/pause-state deterministically, without
    /// constructing a real `TimerService` or waiting on its boundary task.
    static func nearestRemainingLine(timers: [NotchTimer], at now: Date) -> String? {
        guard let nearest = timers.filter({ !$0.isPaused }).min(by: { $0.endDate < $1.endDate }) else { return nil }
        return formatAmbientRemaining(max(nearest.remaining(at: now), 0))
    }

    /// The code-review fix's paused counterpart to `nearestRemainingLine`
    /// above: when every timer is paused (so there's no running one at all),
    /// the ambient wing should still show SOMETHING rather than disappearing
    /// entirely — the nearest (soonest-to-finish, were it resumed right now)
    /// paused timer's frozen remaining time. `now` is threaded through only
    /// for parity with `nearestRemainingLine`'s signature; a paused timer's
    /// `remaining(at:)` ignores whatever instant it's asked about and always
    /// answers with the value frozen at `pausedAt` (see `NotchTimer.
    /// remaining(at:)`'s own doc comment), so passing a slightly-stale `now`
    /// here is harmless. `nil` when no timer is paused (either none exist at
    /// all, or every existing one is currently running).
    static func nearestPausedRemainingLine(timers: [NotchTimer], at now: Date) -> String? {
        guard let nearest = timers.filter(\.isPaused).min(by: { $0.remaining(at: now) < $1.remaining(at: now) }) else { return nil }
        return formatAmbientRemaining(max(nearest.remaining(at: now), 0))
    }

    /// The ambient wing's own countdown format — deliberately DIFFERENT from
    /// `formatCountdown` above, and coupled to
    /// `LiveActivitySources.nextTimerRefreshBoundary`'s refresh cadence:
    /// showing `m:ss` text that's only refreshed once a minute (or once every
    /// 10s) reads as frozen/wrong for most of that interval, since the
    /// seconds digit implies second-level precision the refresh cadence
    /// doesn't deliver. So the format itself changes with the cadence
    /// instead: above 60s remaining, whole minutes only ("4 min"), matching
    /// the once-a-minute refresh exactly — there's no seconds digit left to
    /// go stale. Under 60s remaining, `m:ss` ("0:42") — `nextTimerRefreshBoundary`
    /// switches to a per-second refresh for exactly this window, a deliberate,
    /// bounded (≤60 ticks) exception to the notch suite's no-frequent-timers
    /// perf contract, made once a countdown is in its final minute, where a
    /// visibly live "about to finish" wing is worth the up-to-60 extra wakes.
    static func formatAmbientRemaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        guard seconds > 60 else { return formatCountdown(seconds) }
        let minutes = Int(seconds / 60)
        return "\(minutes) min"
    }

    /// `m:ss`, floor-truncated — mirrors `NowPlayingExpandedView`'s own
    /// scrubber time format (`NowPlayingWidget.swift`) for a consistent
    /// monospaced-time look across the notch suite. Never negative: a
    /// negative or non-finite input (there shouldn't be one in practice —
    /// `TimerService`'s boundary task reaps a timer the same tick its
    /// countdown crosses zero — but this is display code on a path that must
    /// never show garbage) reads as `0:00` instead.
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Presets

    /// Minutes offered as one-tap quick-start capsules.
    static let presetMinutes = [1, 5, 10, 25]

    /// The custom stepper's allowed range.
    static let customMinutesRange = 1...120

    /// The default label a preset/custom-started timer gets — "5 min" for a
    /// 5-minute timer, etc. There is no free-text label entry in this
    /// milestone's UI, so every timer's label is exactly this.
    static func defaultLabel(minutes: Int) -> String {
        "\(minutes) min"
    }
}

// MARK: - Expanded panel view

/// Alcove refit (M7): this panel's total height budget is 185, minus fixed
/// padding leaves a usable content height of roughly 100–150. The fixed
/// chrome above the running list — header (~14, 12pt line), presetRow
/// (~24: 12pt text + 6pt top/bottom padding), customRow (~24, same math),
/// the 1pt divider, and 4 lots of 8pt inter-section spacing — adds up to
/// 14 + 8 + 24 + 8 + 24 + 8 + 1 + 8 = 95, leaving ~5–55 for `content`
/// depending on where in the usable range this panel actually lands; rows
/// were tightened (8pt row spacing → 6, 4pt row vertical padding → 3, see
/// `TimerRow`) precisely so at least one running-timer row plus its own
/// scroll affordance still fits rather than being squeezed out entirely.
private struct TimersExpandedView: View {
    @ObservedObject var service: TimerService

    @State private var customMinutes = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            presetRow
            customRow
            // A plain `Divider()` leans on the system separator color, which
            // reads as near-invisible against this panel's near-black
            // background (unlike the Settings surface `Theme.hairlineColor`
            // is tuned for) — a thin white-opacity rule matches the same
            // faint-line language the wing content already uses elsewhere in
            // the notch UI (`NotchRootView`'s gauge track, `EventRow`'s
            // dividing dot) instead.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        Text("Timers")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.7))
    }

    // MARK: Start controls

    /// Preset capsules: a quiet white wash, not the old amber-tinted one —
    /// amber is gone from every widget surface except calendar dots/
    /// warnings under Alcove's near-monochrome language.
    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(TimersWidget.presetMinutes, id: \.self) { minutes in
                Button {
                    start(minutes: minutes)
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `Start` is the one deliberately brighter control in this row — an
    /// inverted anchor (near-white fill, black text) rather than another
    /// white-wash capsule, so the single primary action still reads as
    /// distinct from the preset row above it even with amber gone.
    private var customRow: some View {
        HStack(spacing: 10) {
            Stepper(value: $customMinutes, in: TimersWidget.customMinutesRange) {
                Text("\(customMinutes) min")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)

            Button("Start") { start(minutes: customMinutes) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.92))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.9)))
        }
    }

    private func start(minutes: Int) {
        service.start(duration: TimeInterval(minutes * 60), label: TimersWidget.defaultLabel(minutes: minutes))
    }

    // MARK: Running list / empty state

    @ViewBuilder
    private var content: some View {
        if service.timers.isEmpty {
            emptyState
        } else {
            runningList
        }
    }

    private var emptyState: some View {
        WidgetEmptyStateView(icon: "timer", message: "No timers running")
    }

    /// One shared 1s tick drives every row's countdown text — but ONLY while
    /// at least one timer is actually running. This is the perf-contract
    /// gate the milestone calls for: the `TimelineView` only exists in the
    /// tree at all while `service.timers` is non-empty (this branch of
    /// `content` is the only place it's built) AND `hasRunningTimer` (below)
    /// is `true`, AND this whole view only exists while the widget itself is
    /// presented — `NotchRootView.expandedContent` only ever calls
    /// `makeExpandedView()` for the currently-`.expanded` widget, the same
    /// structural guarantee `NowPlayingWidget`'s own scrubber tick and
    /// `ShelfWidget`'s doc comment both lean on. An all-paused list has
    /// nothing that could change from one second to the next (`NotchTimer.
    /// remaining` freezes at the pause instant), so ticking it every second
    /// would just be a wasted wake with no visible effect — `rows(now:)` is
    /// rendered once, against a single `Date()`, instead.
    @ViewBuilder
    private var runningList: some View {
        if hasRunningTimer {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                rows(now: timeline.date)
            }
        } else {
            rows(now: Date())
        }
    }

    private var hasRunningTimer: Bool {
        service.timers.contains { !$0.isPaused }
    }

    private func rows(now: Date) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(service.timers) { timer in
                    TimerRow(timer: timer, now: now, service: service)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - One running/paused timer row

private struct TimerRow: View {
    let timer: NotchTimer
    let now: Date
    let service: TimerService

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(TimersWidget.formatCountdown(max(timer.remaining(at: now), 0)))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(timer.isPaused ? Color.white.opacity(0.4) : Color.white)
            }

            Spacer(minLength: 0)

            Button {
                if timer.isPaused {
                    service.resume(timer.id)
                } else {
                    service.pause(timer.id)
                }
            } label: {
                Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            Button {
                service.cancel(timer.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}
