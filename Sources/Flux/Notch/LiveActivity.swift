import Foundation
import Combine

/// A transient piece of "wings" content shown around the collapsed notch —
/// battery/Bluetooth/HUD/timer/etc. Modeled as data (not a view) so
/// `LiveActivityCenter` can reason about priority and expiry without touching
/// SwiftUI; `NotchRootView` is the only thing that renders `Content`.
struct LiveActivity: Identifiable, Equatable {
    /// What produced this activity — also the de-duplication key: posting a
    /// new activity of a kind already queued replaces the old one instead of
    /// stacking (e.g. a fresh battery-percent tick supersedes the stale one).
    enum Kind: Equatable {
        case battery, bluetoothDevice, hudVolume, hudBrightness, timer, shelfDrop, menuBarOverflow, nowPlaying, calendarEvent
    }

    /// What to draw in a wing. Deliberately data-only (no SwiftUI types) so
    /// this model has zero view-layer dependencies.
    enum Content: Equatable {
        case none
        case icon(systemName: String)
        case text(String)
        case iconText(systemName: String, text: String)
        case gauge(Double, systemName: String)
        case artwork
    }

    /// A wing-level color hint, kept data-only like `Content`. The semantic
    /// (not just visual) contract:
    /// - `.normal` = **informational**. The ordinary accent-tinted rendering
    ///   every activity used before M3 (Now Playing, Shelf, plug/unplug,
    ///   Bluetooth connect/disconnect) — and, deliberately, the menu-bar
    ///   overflow warning too. Overflow reads as amber/routine ("N icons
    ///   behind the notch") on purpose: it's a heads-up about a layout
    ///   problem, not an emergency, so it stays `.normal` even though it's
    ///   posted from a type literally named "warning" in `MenuBarArranger`.
    /// - `.warning` = **urgent**, rendered red. Reserved for things that
    ///   actually need to interrupt — right now, only the
    ///   crossed-below-20%-unplugged low-battery notice.
    ///
    /// `NotchRootView` is the only place this turns into an actual `Color`.
    enum ActivityTint: Equatable {
        case normal, warning
    }

    let id: UUID
    let kind: Kind
    /// Rendered in the left wing.
    let leading: Content
    /// Rendered in the right wing.
    let trailing: Content
    /// Lifetime from when it's posted; `nil` means sticky — stays `current`
    /// until explicitly dismissed (e.g. a running timer).
    let duration: TimeInterval?
    /// Higher wins when multiple activities are queued. Suggested bands:
    /// HUD (volume/brightness) 300 > battery 200 > menu-bar overflow 150 >
    /// bluetooth 100.
    let priority: Int
    /// Defaults to `.normal` so every pre-M3 call site (Now Playing, Shelf,
    /// menu-bar overflow) is unaffected by this field's addition.
    let tint: ActivityTint

    init(id: UUID = UUID(), kind: Kind, leading: Content, trailing: Content,
         duration: TimeInterval?, priority: Int, tint: ActivityTint = .normal) {
        self.id = id
        self.kind = kind
        self.leading = leading
        self.trailing = trailing
        self.duration = duration
        self.priority = priority
        self.tint = tint
    }
}

/// Priority queue for the notch's live-activity wings. Exactly one activity is
/// ever `current`; posting a lower-priority activity while a higher one is
/// showing just queues it — it becomes `current` only once nothing
/// higher-priority remains.
///
/// Expiry is a single cancellable `Task.sleep` deadline per activity, armed
/// only for activities that have a `duration` — no repeating timers, matching
/// the notch suite's idle-CPU-zero perf contract.
@MainActor
final class LiveActivityCenter: ObservableObject {
    @Published private(set) var current: LiveActivity?

    private var queue: [LiveActivity] = []
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    /// Post a new activity. An already-queued activity of the same `kind` is
    /// superseded — but exactly how depends on whether the new content is
    /// actually different:
    /// - Equal content (leading/trailing/tint/priority/duration, ignoring
    ///   `id`): this is a key-repeat storm (a HUD gauge reposting the same
    ///   value every ~30ms while a volume key is held) or an equivalent
    ///   no-op re-post — the existing activity's `id` is kept as-is and only
    ///   its expiry deadline is reset (cancel + reschedule the one `Task`).
    ///   Nothing about `current`/`queue` identity changes, so this never
    ///   costs a SwiftUI remove+insert on a view that's already showing.
    /// - Different content (e.g. the gauge actually moved): the queued entry
    ///   is replaced, but — the same fix — the OLD entry's `id` is kept on
    ///   the REPLACEMENT rather than adopting the freshly-constructed
    ///   activity's own `id`, so SwiftUI still sees this as an update to the
    ///   existing `Identifiable` view rather than a remove+insert of a new
    ///   one.
    /// Only when no activity of this `kind` is queued at all does the new
    /// activity's own `id` get used verbatim.
    func post(_ activity: LiveActivity) {
        if let index = queue.firstIndex(where: { $0.kind == activity.kind }) {
            let existing = queue[index]
            if Self.hasEqualContent(existing, activity) {
                scheduleExpiry(for: existing)
                return
            }
            let replacement = LiveActivity(id: existing.id, kind: activity.kind, leading: activity.leading,
                                            trailing: activity.trailing, duration: activity.duration,
                                            priority: activity.priority, tint: activity.tint)
            queue[index] = replacement
            scheduleExpiry(for: replacement)
            recomputeCurrent()
            return
        }
        queue.append(activity)
        scheduleExpiry(for: activity)
        recomputeCurrent()
    }

    /// Same `kind` plus every field but `id` — the equality `post` uses to
    /// tell a genuine no-op repost apart from a real content change.
    private static func hasEqualContent(_ a: LiveActivity, _ b: LiveActivity) -> Bool {
        a.kind == b.kind && a.leading == b.leading && a.trailing == b.trailing
            && a.duration == b.duration && a.priority == b.priority && a.tint == b.tint
    }

    /// Dismiss one activity by id — used when the thing driving it (a widget,
    /// a monitor) decides it's done early, before its deadline.
    func dismiss(id: UUID) {
        guard queue.contains(where: { $0.id == id }) else { return }
        queue.removeAll { $0.id == id }
        cancelExpiry(for: id)
        recomputeCurrent()
    }

    /// Dismiss every queued activity of a kind — used by the producer side
    /// (`NotchActivityRouter` et al.) when a whole category of activity
    /// should go away outright (HUD toggled off, permission revoked), not by
    /// `post` itself: `post`'s own same-kind supersession (see its doc
    /// comment) updates the existing entry in place rather than dismissing
    /// and re-inserting it.
    func dismiss(kind: LiveActivity.Kind) {
        let ids = queue.filter { $0.kind == kind }.map(\.id)
        guard !ids.isEmpty else { return }
        queue.removeAll { $0.kind == kind }
        for id in ids { cancelExpiry(for: id) }
        recomputeCurrent()
    }

    // MARK: - Priority resolution

    /// Highest-priority queued activity becomes `current`; ties keep whichever
    /// was posted first (stable — `max(by:)` only replaces its running result
    /// on a *strict* increase), so equal-priority activities don't flicker
    /// between each other on every recompute.
    private func recomputeCurrent() {
        current = queue.max { $0.priority < $1.priority }
    }

    // MARK: - Expiry

    private func scheduleExpiry(for activity: LiveActivity) {
        let id = activity.id
        // Cancel any previously scheduled deadline for this id unconditionally
        // — including when the new `duration` is `nil` — so an activity that
        // transitions from timed to sticky on a same-id repost/replace
        // (`post`'s dedupe/update paths) doesn't leave a stale timer that
        // dismisses it out from under the sticky state.
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
        guard let duration = activity.duration else { return } // nil = sticky, no deadline
        expiryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    private func cancelExpiry(for id: UUID) {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
    }
}
