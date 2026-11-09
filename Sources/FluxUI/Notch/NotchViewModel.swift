import AppKit
import Combine
import FluxCore
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchViewModel.swift.
// The widget registry and the activity center are replaced by the native
// ordered widget list and the `ActivityQueue` item the parent sends.

/// What the notch shows.
public enum NotchState: Equatable, Sendable {
    case collapsed
    case activity(UUID)
    case expanded(FluxCore.Widget)
}

/// A recognized two-finger swipe over the open notch.
public enum NotchSwipeDirection: Sendable {
    case left, right, down, up
}

/// The notch state machine. Every input goes through `transition(to:)`, the
/// one place that changes `state` and calls the present and dismiss hooks.
/// The only delayed transition is the hover-out close.
@MainActor
public final class NotchViewModel: ObservableObject {
    @Published public private(set) var state: NotchState = .collapsed
    /// The visible shape in the panel's top-left space. The root view writes it.
    @Published public var interactiveRect: CGRect = .zero
    @Published public var hoverHint = false
    @Published public var duoActive = false
    @Published public private(set) var lastTransitionWasShrink = false
    /// The current live activity and its artwork.
    @Published public private(set) var activity: ActivityItem?
    @Published public private(set) var activityArtwork: NSImage?
    /// Enabled widgets in saved order.
    @Published public private(set) var widgets: [FluxCore.Widget] = []

    public var expansionTrigger: ExpansionTrigger = .hover {
        didSet {
            guard expansionTrigger != oldValue else { return }
            cancelHoverTasks()
        }
    }

    public var hoverCloseDelay: TimeInterval = 0.40

    /// Called before the state moves to `.expanded(to)`.
    public var onPresent: (@MainActor (_ from: FluxCore.Widget?, _ to: FluxCore.Widget) -> Void)?
    /// Called before an expanded widget stops being shown.
    public var onDismiss: (@MainActor (FluxCore.Widget) -> Void)?
    /// Called after every state change.
    public var onStateChange: (@MainActor (NotchState) -> Void)?
    /// Queue actions. The parent owns the queue.
    public var onCycleActivity: (@MainActor () -> Void)?
    public var onDismissActivity: (@MainActor () -> Void)?
    public var onRestoreActivity: (@MainActor () -> Void)?
    /// A tap on a live activity. Return true to claim it.
    public var onActivityTap: (@MainActor (ActivityKind) -> Bool)?
    /// The SwiftUI content for an expanded widget.
    public var widgetContent: (@MainActor (FluxCore.Widget) -> AnyView?)?

    private var lastUsedWidget: FluxCore.Widget?
    private var isHovering = false
    private var hoverCloseTask: Task<Void, Never>?
    private var dragAutoExpanded = false
    private var isTransitioning = false
    private var needsActivityReconcile = false

    public init() {}

    deinit { hoverCloseTask?.cancel() }

    // MARK: Shrink rule

    public static func footprintRank(_ state: NotchState) -> Int {
        switch state {
        case .collapsed: return 0
        case .activity: return 1
        case .expanded: return 2
        }
    }

    public static func isShrink(from old: NotchState, to new: NotchState) -> Bool {
        footprintRank(new) < footprintRank(old)
    }

    // MARK: Parent data

    /// A live activity preempts `.collapsed` and updates `.activity`. It never
    /// disturbs `.expanded`; the next collapse surfaces it.
    public func setActivity(_ item: ActivityItem?, artwork: NSImage?) {
        let changed = activity != item || activityArtwork !== artwork
        activity = item
        activityArtwork = item == nil ? nil : artwork
        guard !isTransitioning else { needsActivityReconcile = true; return }
        applyActivity(item, contentChanged: changed)
    }

    /// The enabled widgets. A shown widget that left the list is re-resolved.
    public func setWidgets(_ list: [FluxCore.Widget]) {
        var seen = Set<FluxCore.Widget>()
        let unique = list.filter { seen.insert($0).inserted }
        guard unique != widgets else { return }
        widgets = unique
        if case .expanded(let current) = state, !unique.contains(current) { expand(nil) }
    }

    // MARK: Inputs

    public var suppressHover = false {
        didSet {
            guard suppressHover, suppressHover != oldValue else { return }
            cancelHoverTasks()
        }
    }

    /// Forgets hover without reporting a hover-out. For teardown only.
    public func resetHoverState() {
        cancelHoverTasks()
        isHovering = false
        if hoverHint { hoverHint = false }
    }

    /// Re-derives hover from the real pointer, bypassing both debounces.
    public func resyncHover(inside: Bool) {
        suppressHover = false
        isHovering = !inside
        hoverChanged(inside: inside)
    }

    public func hoverChanged(inside: Bool) {
        guard !suppressHover else { return }
        if hoverHint != inside { hoverHint = inside }
        guard inside != isHovering else { return }
        isHovering = inside
        guard expansionTrigger == .hover else { return }
        if inside {
            hoverCloseTask?.cancel()
            hoverCloseTask = nil
            guard !isExpanded else { return }
            expand(nil)
        } else {
            hoverCloseTask?.cancel()
            let delay = hoverCloseDelay
            hoverCloseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    /// A click toggles in either trigger mode. Option-click restores the
    /// last dismissed activity instead.
    public func clicked(optionDown: Bool = false) {
        guard !optionDown else {
            onRestoreActivity?()
            return
        }
        toggleExpansion()
    }

    public func swiped(_ direction: NotchSwipeDirection) {
        switch direction {
        case .down:
            switch state {
            case .collapsed, .activity: expand(nil)
            case .expanded: break
            }
        case .up:
            if case .activity = state { onDismissActivity?() } else { collapse() }
        case .left:
            switch state {
            case .expanded: cycle(forward: true)
            case .activity: onCycleActivity?()
            case .collapsed: break
            }
        case .right:
            switch state {
            case .expanded: cycle(forward: false)
            case .activity: onCycleActivity?()
            case .collapsed: break
            }
        }
    }

    public func hotkeyToggled() { toggleExpansion() }

    /// Collapse, surfacing a current live activity instead of going blank.
    public func collapse() {
        transition(to: activity.map { .activity($0.id) } ?? .collapsed)
    }

    /// Straight to `.collapsed`, for teardown.
    public func forceCollapse() {
        transition(to: .collapsed)
    }

    /// Opens `id`, else the last used widget, else the first enabled one.
    public func expand(_ id: FluxCore.Widget?) {
        guard !widgets.isEmpty else {
            collapse()
            return
        }
        let resolved: FluxCore.Widget
        if let id, widgets.contains(id) {
            resolved = id
        } else if let last = lastUsedWidget, widgets.contains(last) {
            resolved = last
        } else {
            resolved = widgets[0]
        }
        transition(to: .expanded(resolved))
    }

    /// The tap rule from `NotchRootView.handleTap`.
    public func handleTap(optionDown: Bool) {
        guard !optionDown else {
            clicked(optionDown: true)
            return
        }
        if case .activity = state, let kind = activity?.kind, onActivityTap?(kind) == true { return }
        clicked()
    }

    // MARK: File drags

    /// A file drag entered the collapsed notch: open File Shelf.
    public func dragEntered() {
        guard state == .collapsed else { return }
        guard widgets.contains(.shelf) else { return }
        dragAutoExpanded = true
        expand(.shelf)
    }

    /// The drag left without a drop. Close only a shelf this drag opened.
    public func dragExited() {
        guard dragAutoExpanded, state == .expanded(.shelf) else { return }
        dragAutoExpanded = false
        collapse()
    }

    public func dragCompleted() {
        dragAutoExpanded = false
    }

    public var isDragAutoExpanded: Bool { dragAutoExpanded }

    // MARK: Internals

    public var isExpanded: Bool {
        if case .expanded = state { return true }
        return false
    }

    private func toggleExpansion() {
        if isExpanded { collapse() } else { expand(nil) }
    }

    private func cycle(forward: Bool) {
        guard case .expanded(let current) = state, !widgets.isEmpty else { return }
        let next: FluxCore.Widget
        if let index = widgets.firstIndex(of: current) {
            next = widgets[(index + (forward ? 1 : -1) + widgets.count) % widgets.count]
        } else {
            next = forward ? widgets[0] : widgets[widgets.count - 1]
        }
        transition(to: .expanded(next))
    }

    private func cancelHoverTasks() {
        hoverCloseTask?.cancel(); hoverCloseTask = nil
    }

    private func applyActivity(_ item: ActivityItem?, contentChanged: Bool) {
        switch state {
        case .collapsed:
            if let item { transition(to: .activity(item.id)) }
        case .activity:
            let next: NotchState = item.map { .activity($0.id) } ?? .collapsed
            if next == state {
                if contentChanged { objectWillChange.send() }
            } else {
                transition(to: next)
            }
        case .expanded:
            break
        }
    }

    private func transition(to newState: NotchState) {
        guard newState != state else { return }
        isTransitioning = true
        defer {
            isTransitioning = false
            if needsActivityReconcile {
                needsActivityReconcile = false
                applyActivity(activity, contentChanged: true)
            }
        }
        let old = state
        var oldWidget: FluxCore.Widget?
        if case .expanded(let id) = old { oldWidget = id }
        if let oldWidget, !Self.isExpandedState(newState) { onDismiss?(oldWidget) }
        if case .expanded(let id) = newState {
            lastUsedWidget = id
            onPresent?(oldWidget, id)
        }
        lastTransitionWasShrink = Self.isShrink(from: old, to: newState)
        state = newState
        if newState == .collapsed { dragAutoExpanded = false }
        onStateChange?(newState)
    }

    private static func isExpandedState(_ state: NotchState) -> Bool {
        if case .expanded = state { return true }
        return false
    }
}
