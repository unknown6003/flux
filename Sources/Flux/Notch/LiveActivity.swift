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
        case battery, bluetoothDevice, hudVolume, hudBrightness, timer, shelfDrop, menuBarOverflow, nowPlaying
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
    /// HUD (volume/brightness) 300 > battery 200 > bluetooth 100.
    let priority: Int

    init(id: UUID = UUID(), kind: Kind, leading: Content, trailing: Content,
         duration: TimeInterval?, priority: Int) {
        self.id = id
        self.kind = kind
        self.leading = leading
        self.trailing = trailing
        self.duration = duration
        self.priority = priority
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

    /// Post a new activity. Any already-queued activity of the same `kind` is
    /// dismissed first (a fresh event supersedes the stale one), then priority
    /// is re-resolved.
    func post(_ activity: LiveActivity) {
        dismiss(kind: activity.kind)
        queue.append(activity)
        scheduleExpiry(for: activity)
        recomputeCurrent()
    }

    /// Dismiss one activity by id — used when the thing driving it (a widget,
    /// a monitor) decides it's done early, before its deadline.
    func dismiss(id: UUID) {
        guard queue.contains(where: { $0.id == id }) else { return }
        queue.removeAll { $0.id == id }
        cancelExpiry(for: id)
        recomputeCurrent()
    }

    /// Dismiss every queued activity of a kind (also used internally by
    /// `post` to de-duplicate before inserting the replacement).
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
        guard let duration = activity.duration else { return } // nil = sticky, no deadline
        let id = activity.id
        expiryTasks[id]?.cancel()
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
