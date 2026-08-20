import Foundation

/// Pure formatting and selection helpers for the timer live activity.
///
/// Timers are no longer a full notch page. `TimerService` remains the source
/// of truth, while this small value-only surface lets the live activity stay
/// useful when a timer is running without bringing the old timer widget back.
enum TimerActivity {
    /// Short presets exposed from Flux's shared context menu.
    static let presetMinutes = [1, 5, 10, 25]

    static func defaultLabel(minutes: Int) -> String {
        "\(minutes) min"
    }

    /// The soonest-to-finish running timer, rendered for the live wing.
    static func nearestRemainingLine(timers: [NotchTimer], at now: Date) -> String? {
        guard let nearest = timers
            .filter({ !$0.isPaused })
            .min(by: { $0.endDate < $1.endDate }) else { return nil }
        return formatAmbientRemaining(max(nearest.remaining(at: now), 0))
    }

    /// A paused timer still deserves a visible live-activity row. Its value is
    /// frozen, so the nearest paused timer is enough when none are running.
    static func nearestPausedRemainingLine(timers: [NotchTimer], at now: Date) -> String? {
        guard let nearest = timers
            .filter(\.isPaused)
            .min(by: { $0.remaining(at: now) < $1.remaining(at: now) }) else { return nil }
        return formatAmbientRemaining(max(nearest.remaining(at: now), 0))
    }

    /// Always show second precision. The router refreshes this value once per
    /// second, so the wing reads like a live countdown instead of a stale
    /// minute estimate.
    static func formatAmbientRemaining(_ seconds: TimeInterval) -> String {
        formatCountdown(seconds)
    }

    /// `m:ss`, rolling to `h:mm:ss` for long timers.
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
