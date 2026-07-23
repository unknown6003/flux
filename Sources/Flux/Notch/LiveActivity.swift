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
        case battery, bluetoothDevice, hudVolume, timer, shelfDrop, menuBarOverflow, nowPlaying, calendarEvent
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

    /// A plain-text caption derived from this activity's own content —
    /// what `LockScreenPresenter` should caption its silhouette with when
    /// wired to "whatever's currently showing" generically, rather than a
    /// hardcoded dependency on any one producer (e.g. timers specifically).
    /// Prefers `trailing` over `leading` since that's where every existing
    /// producer's actual text lives (`.text`/`.iconText` on battery/timer/
    /// calendar/menu-bar-overflow activities); falls back to `leading` in
    /// case some future producer puts its text there instead. `nil` for an
    /// icon-only/gauge/artwork/`.none` activity on both sides — nothing
    /// there to caption with.
    var captionText: String? {
        Self.text(from: trailing) ?? Self.text(from: leading)
    }

    private static func text(from content: Content) -> String? {
        switch content {
        case .text(let value): return value
        case .iconText(_, let value): return value
        case .none, .icon, .gauge, .artwork: return nil
        }
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
    /// One `DeadlineTask` per still-queued activity that has a `duration` —
    /// see that type's own doc comment for the shared cancel/reschedule
    /// shape this backs.
    private var expiryTasks: [UUID: DeadlineTask] = [:]

    /// M7 (Alcove parity): set by `cycle()`, read by `recomputeCurrent()`.
    /// While this points at a still-queued activity, that activity is
    /// `current` unconditionally — overriding the plain priority-max
    /// resolution below — so a user explicitly swiping through activities
    /// isn't immediately overridden by whatever the priority queue would
    /// otherwise pick. This is a deliberate, simple tradeoff: a transient
    /// activity (a HUD flash, a plug/unplug toast) posted while the cursor is
    /// parked on some other activity won't preempt it and will simply expire
    /// unseen — acceptable since the common case (no explicit cycling
    /// in progress) is untouched, and the cursor self-clears the moment its
    /// own target activity is dismissed/expires (see `recomputeCurrent`),
    /// returning to plain priority resolution on its own.
    private var cycleCursor: UUID?

    /// Dismissed (restorable) activities the user swiped away, most recent
    /// last — capped at `dismissedStackCap` so a long session of dismiss/
    /// restore never grows unbounded. Only populated by
    /// `dismissCurrent(restorable: true)`; `restoreLastDismissed()` is the
    /// only consumer.
    private var dismissedStack: [LiveActivity] = []
    private static let dismissedStackCap = 5

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

    // MARK: - Cycling (M7: Alcove-style swipe-through-activities)

    /// Rotates `current` among queued STICKY (`duration == nil`) activities —
    /// the Alcove swipe-left/right-while-an-activity-is-showing gesture.
    /// Transient activities (a HUD flash, a plug/unplug toast) aren't part of
    /// this ring at all — they keep expiring on their own regardless of where
    /// the cursor points; see `cycleCursor`'s own doc comment for the
    /// resulting (deliberate) tradeoff. The ring order is the queue's own
    /// array order (stable: a same-kind repost updates in place rather than
    /// moving position — see `post(_:)`), starting from wherever the cursor
    /// (or, absent one, whatever's currently `current`) already sits. A no-op
    /// with no sticky activities queued at all — nothing to cycle to.
    func cycle() {
        let stickyIDs = queue.filter { $0.duration == nil }.map(\.id)
        guard !stickyIDs.isEmpty else { return }
        let startID = cycleCursor ?? current?.id
        let currentIndex = startID.flatMap { stickyIDs.firstIndex(of: $0) }
        let nextIndex = currentIndex.map { ($0 + 1) % stickyIDs.count } ?? 0
        cycleCursor = stickyIDs[nextIndex]
        recomputeCurrent()
    }

    /// Dismisses whatever's `current` right now — the Alcove "swipe up to
    /// dismiss the showing activity" gesture. `restorable` pushes a copy onto
    /// `dismissedStack` first, so `restoreLastDismissed()` can bring it back;
    /// pass `false` for a dismissal that should be gone for good. A no-op
    /// with nothing currently showing.
    func dismissCurrent(restorable: Bool) {
        guard let activity = current else { return }
        if restorable {
            dismissedStack.append(activity)
            if dismissedStack.count > Self.dismissedStackCap {
                dismissedStack.removeFirst(dismissedStack.count - Self.dismissedStackCap)
            }
        }
        dismiss(id: activity.id)
    }

    /// Re-queues the most recently dismissed restorable activity (if any) and
    /// makes it `current` again unconditionally, regardless of priority — by
    /// pointing `cycleCursor` at it, the same "explicit user navigation wins"
    /// mechanism `cycle()` itself relies on. A no-op with nothing to restore.
    ///
    /// Bot-review fix: this used to re-queue the dismissed activity with a
    /// bare `queue.append(activity)` — bypassing `post(_:)`'s own
    /// one-entry-per-`kind` invariant entirely. If some OTHER activity of the
    /// same `kind` had been posted in the meantime (entirely plausible: the
    /// dismissed stack can hold an activity for a while, and its producer
    /// keeps running), that append left TWO queued entries of the same kind
    /// at once — an invariant every other mutating method on this type
    /// (`post`, `dismiss(kind:)`) assumes never happens. Routing through
    /// `post(_:)` instead reuses its exact same-kind supersession logic (see
    /// its own doc comment): a genuine dup gets replaced in place, not
    /// stacked. `post` may keep the ALREADY-queued same-kind entry's own `id`
    /// on the replacement rather than `activity`'s (again, see `post`'s doc
    /// comment on why) — so `cycleCursor` is pointed at whichever id actually
    /// ended up queued for `activity.kind` after the call, not blindly at
    /// `activity.id`, which could now be stale.
    func restoreLastDismissed() {
        guard let activity = dismissedStack.popLast() else { return }
        post(activity)
        if let queuedID = queue.first(where: { $0.kind == activity.kind })?.id {
            cycleCursor = queuedID
        }
        recomputeCurrent()
    }

    // MARK: - Priority resolution

    /// The cursor `cycle()`/`restoreLastDismissed()` set wins unconditionally
    /// as long as its target activity is still queued; otherwise this clears
    /// the (now-stale) cursor and falls back to the plain priority-max
    /// resolution every activity used before M7 — highest priority wins, ties
    /// keep whichever was posted first (stable — `max(by:)` only replaces its
    /// running result on a *strict* increase), so equal-priority activities
    /// don't flicker between each other on every recompute.
    private func recomputeCurrent() {
        if let cycleCursor, let cursored = queue.first(where: { $0.id == cycleCursor }) {
            current = cursored
            return
        }
        cycleCursor = nil
        current = queue.max { $0.priority < $1.priority }
    }

    // MARK: - Expiry

    private func scheduleExpiry(for activity: LiveActivity) {
        let id = activity.id
        guard let duration = activity.duration else {
            // Cancel any previously scheduled deadline for this id — an
            // activity that transitions from timed to sticky on a same-id
            // repost/replace (`post`'s dedupe/update paths) must not leave a
            // stale timer that dismisses it out from under the sticky state.
            expiryTasks[id]?.cancel()
            expiryTasks[id] = nil
            return
        }
        let deadlineTask = expiryTasks[id] ?? DeadlineTask()
        expiryTasks[id] = deadlineTask
        deadlineTask.reschedule(to: Date().addingTimeInterval(duration)) { [weak self] in
            self?.dismiss(id: id)
        }
    }

    private func cancelExpiry(for id: UUID) {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
    }
}
