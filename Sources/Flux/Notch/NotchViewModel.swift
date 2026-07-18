import Foundation
import Combine

/// What the notch is currently showing. `activity`/`expanded` carry the id of
/// the thing being shown so the view can look it up (`LiveActivityCenter`,
/// `NotchWidgetRegistry`) without the state machine holding a live reference.
enum NotchState: Equatable {
    case collapsed
    case activity(UUID)
    case expanded(WidgetID)
}

/// Which gesture opens the notch. Persisted by the wiring agent; hover is the
/// default.
enum NotchExpansionTrigger: String, Codable {
    case hover, click
}

/// A recognized two-finger swipe over the notch panel, forwarded here by
/// `NotchPanel.sendEvent`'s `scrollWheel` handling.
enum SwipeDirection {
    case left, right, down, up
}

/// The notch's state machine.
///
/// Owns exactly one piece of mutable truth — `state` — and every input
/// (hover, click, swipe, hotkey, or a `LiveActivityCenter` update) funnels
/// through `transition(to:)`, the single place that mutates it and fires
/// `NotchWidget.willPresent()/didDismiss()`. That keeps the pairing exact:
/// each becomes-visible gets exactly one `willPresent`, each
/// stops-being-visible gets exactly one `didDismiss`, no matter which input
/// caused the move — which is the perf contract the whole notch suite leans
/// on (a widget that's never told to stop can't be blamed for leaking).
///
/// Deliberately view-free: everything here is plain state and `Task`-based
/// delays, so `--selftest` can drive the full transition table without a
/// window server.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .collapsed

    /// The current visual bounds that should hit-test as "inside the notch"
    /// (collapsed = the physical notch rect; activity/expanded = the wider
    /// shape) — in the hosting view's own coordinate space. `NotchRootView`
    /// writes this every time its shape's geometry changes; `NotchHostingView`
    /// reads it for `hitTest` pass-through and hover containment.
    @Published var interactiveRect: CGRect = .zero

    /// A subtle "I'm hoverable" breathing cue for click mode, where hovering
    /// doesn't itself open anything. Updated in both trigger modes (it's just
    /// a cheap boolean), but only click-mode UI needs to look at it.
    @Published var hoverHint = false

    /// Which gesture opens the notch. Switching to `.click` cancels any
    /// in-flight hover-intent delay so a stale timer can't fire an open/close
    /// after the mode that scheduled it no longer applies.
    var expansionTrigger: NotchExpansionTrigger {
        didSet {
            guard expansionTrigger != oldValue else { return }
            cancelHoverTasks()
        }
    }

    /// Hover-in intent delay before expanding — long enough that a cursor
    /// merely passing over the notch on its way to the clock doesn't trigger
    /// it, short enough to feel responsive when the user actually pauses.
    var hoverOpenDelay: TimeInterval = 0.15

    /// Hover-out intent delay before collapsing — longer than the open delay
    /// so a brief flick off the notch (e.g. to glance at another wing) or the
    /// gap while the cursor crosses the notch's own bezel doesn't slam it shut.
    var hoverCloseDelay: TimeInterval = 0.40

    let registry: NotchWidgetRegistry
    let activities: LiveActivityCenter

    /// The most recently expanded widget, so `expand(nil)` (hover-open,
    /// hotkey, click) reopens where the user left off instead of always
    /// resetting to the first widget.
    private var lastUsedWidget: WidgetID?

    /// Debounced enter/exit intent, tracked separately from `state` so the
    /// (frequent) `mouseMoved` re-deliveries within an unchanged hover state
    /// are cheap no-ops rather than restarting the delay on every pixel.
    private var isHovering = false
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    init(registry: NotchWidgetRegistry,
         activities: LiveActivityCenter,
         expansionTrigger: NotchExpansionTrigger = .hover) {
        self.registry = registry
        self.activities = activities
        self.expansionTrigger = expansionTrigger
        observeActivities()
    }

    deinit {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
    }

    // MARK: - Live activities

    /// A live activity preempts `.collapsed` and updates while already
    /// showing as `.activity`; it never disturbs `.expanded` (the widget
    /// panel wins while it's open) — ending or losing the activity there is
    /// only noticed the next time something collapses (`collapse()` re-checks
    /// `activities.current`).
    private func observeActivities() {
        activities.$current
            .removeDuplicates()
            .sink { [weak self] activity in
                guard let self else { return }
                switch self.state {
                case .collapsed:
                    if let activity { self.transition(to: .activity(activity.id)) }
                case .activity:
                    self.transition(to: activity.map { .activity($0.id) } ?? .collapsed)
                case .expanded:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Inputs

    /// Debounced hover containment. `inside` is `interactiveRect.contains(point)`,
    /// recomputed by the hosting view on every enter/exit/moved event — so this
    /// is called far more often than the hover state actually changes; the
    /// `isHovering` guard below turns the redundant calls into no-ops instead
    /// of continuously restarting the open/close delay while the cursor merely
    /// wanders inside (or stays outside) the same region.
    func hoverChanged(inside: Bool) {
        hoverHint = inside
        guard inside != isHovering else { return }
        isHovering = inside
        guard expansionTrigger == .hover else { return }

        if inside {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            guard !isExpanded else { return }   // already open; nothing to schedule
            hoverOpenTask?.cancel()
            let delay = hoverOpenDelay
            hoverOpenTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.expand(nil)
            }
        } else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            hoverCloseTask?.cancel()
            let delay = hoverCloseDelay
            hoverCloseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    /// A click on the notch. Acts as a plain open/close toggle regardless of
    /// `expansionTrigger` — in hover mode a click is still the fast path to
    /// pin the panel open without waiting out the hover delay; in click mode
    /// it's the *only* way in, per `expansionTrigger`.
    func clicked() {
        toggleExpansion()
    }

    /// Cycles widgets left/right while expanded; `down` opens from collapsed;
    /// `up` collapses from anywhere. Left/right are no-ops outside `.expanded`
    /// — there's nothing to cycle through in the collapsed or activity wings.
    func swiped(_ direction: SwipeDirection) {
        switch direction {
        case .down:
            if state == .collapsed { expand(nil) }
        case .up:
            collapse()
        case .left:
            cycle(forward: true)
        case .right:
            cycle(forward: false)
        }
    }

    /// The global hotkey toggle — same open/close semantics as `clicked()`.
    func hotkeyToggled() {
        toggleExpansion()
    }

    /// Collapse the panel. If a live activity is still current (it was
    /// preempted while a widget was expanded), surface that instead of going
    /// fully collapsed — matching `.activity`'s own preemption rule so the
    /// user doesn't lose a still-relevant battery/HUD/timer wing just because
    /// they happened to have a widget open when it arrived.
    func collapse() {
        transition(to: activities.current.map { .activity($0.id) } ?? .collapsed)
    }

    /// Expand to a specific widget, or (when `id` is `nil`, or that widget
    /// isn't currently enabled) the last-used widget, or the first enabled
    /// one. A no-op when no widget is enabled at all.
    func expand(_ id: WidgetID?) {
        let enabledIDs = registry.enabledWidgets.map(\.id)
        guard !enabledIDs.isEmpty else { return }

        let resolved: WidgetID
        if let id, enabledIDs.contains(id) {
            resolved = id
        } else if let last = lastUsedWidget, enabledIDs.contains(last) {
            resolved = last
        } else {
            resolved = enabledIDs[0]
        }
        transition(to: .expanded(resolved))
    }

    // MARK: - Internals

    private var isExpanded: Bool {
        if case .expanded = state { return true }
        return false
    }

    private func toggleExpansion() {
        if isExpanded {
            collapse()
        } else {
            expand(nil)
        }
    }

    private func cycle(forward: Bool) {
        guard case .expanded(let currentID) = state else { return }
        let next = forward ? registry.next(after: currentID) : registry.previous(before: currentID)
        guard let next else { return }
        transition(to: .expanded(next))
    }

    private func cancelHoverTasks() {
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
    }

    /// The single place `state` is mutated. Diffs the outgoing/incoming
    /// widget against `registry` so `willPresent`/`didDismiss` fire exactly
    /// once per visibility change — including widget→widget swipes, which
    /// move directly from one `.expanded` case to another without an
    /// intermediate collapse.
    private func transition(to newState: NotchState) {
        guard newState != state else { return }

        if case .expanded(let oldID) = state {
            registry.widget(for: oldID)?.didDismiss()
        }

        state = newState

        if case .expanded(let newID) = newState {
            lastUsedWidget = newID
            registry.widget(for: newID)?.willPresent()
        }
    }
}
