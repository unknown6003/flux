import AppKit
import SwiftUI

/// The always-present, transparent panel the notch UI lives in.
///
/// One instance, sized to the max-expanded bounds and never resized after
/// creation (`NotchWindowController` repositions it on screen changes; the
/// *visual* growth/shrink between collapsed/activity/expanded is done entirely
/// by SwiftUI inside `NotchRootView` — animating an `NSPanel`'s own frame
/// tears and can't be interrupted mid-flight at high refresh rates, which
/// animating the content inside a fixed panel avoids entirely).
///
/// Borderless + `.nonactivatingPanel` so it never takes key window or steals
/// focus from whatever app the user is in; `.statusBar` level and the
/// `canJoinAllSpaces`/`fullScreenAuxiliary` collection behavior so it rides
/// above normal windows and survives Space switches and fullscreen apps, the
/// same recipe `NotchHighlightWindow` already uses for the overflow glow.
///
/// ## Why `hitTest` returning `nil` isn't enough for pass-through
///
/// `NotchHostingView.hitTest` declines the point (returns `nil`) everywhere
/// outside the currently-visible notch shape, which is the right idea — but
/// it only decides how *this window* dispatches the event to *its own view
/// hierarchy*. AppKit never retargets a declined hit-test to whatever window
/// happens to be sitting underneath; the event is simply consumed by this
/// window (or dropped) either way. Since this panel is fixed at 600×280+ and
/// frontmost at `.statusBar` level, that means a big transparent rectangle
/// across the top-center of the screen would swallow every click and scroll
/// aimed at another app passing through it — `hitTest` alone only stops
/// *this panel's own SwiftUI content* from reacting, not the window itself
/// from claiming the event.
///
/// The actual fix is `NSWindow.ignoresMouseEvents`, toggled by
/// `NotchWindowController` to match `NotchViewModel.state`: `true` while
/// `.collapsed` (the physical notch has no interactive pixels of its own
/// regardless, so nothing is lost) truly hands every event to whatever's
/// beneath, and `false` while `.activity`/`.expanded` restores normal
/// hit-testing for the wider shape's real interactive content. Collapsed
/// hover/click detection moves to global+local `NSEvent` monitors in that
/// state (see `NotchWindowController`), since a window that ignores mouse
/// events also stops seeing them itself.
final class NotchPanel: NSPanel {
    private let viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Safe starting point matching the state machine's own initial
        // `.collapsed` value; `NotchWindowController` immediately re-syncs
        // this to the live state once the panel is attached/shown.
        ignoresMouseEvents = true
        // See the "Drag-and-drop destination" section below for why this is
        // registered on the window itself.
        registerForDraggedTypes([.fileURL])
    }

    /// Never key: taking key focus would (a) steal it from whatever app the
    /// user is typing into and (b) isn't needed — every interaction the notch
    /// supports (hover, click, scroll) works on a non-key panel.
    override var canBecomeKey: Bool { false }

    /// Toggles `.fullScreenAuxiliary` to match `SettingsStore.
    /// notchShowInFullscreen`, live — called from `NotchWindowController`
    /// instead of only being decided once in `init`, so flipping the
    /// preference takes effect immediately without tearing the panel down.
    func setShowInFullscreen(_ show: Bool) {
        if show {
            collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            collectionBehavior.remove(.fullScreenAuxiliary)
        }
    }

    // MARK: - Swipe recognition

    /// Minimum accumulated scroll distance (points) before a gesture commits
    /// to a swipe direction — small enough to feel responsive, large enough
    /// that a scroll merely passing near the notch isn't misread as one.
    private static let swipeThreshold: CGFloat = 40

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    /// Set once a gesture has already fired a swipe, so continuing to scroll
    /// past the threshold within the *same* two-finger gesture doesn't queue
    /// up several more swipes — one physical gesture is one logical swipe.
    private var gestureConsumed = false

    /// Intercepts `scrollWheel` ahead of normal event dispatch so a two-finger
    /// gesture over the notch cycles/opens/closes it instead of (having no
    /// effect, since nothing beneath this transparent panel scrolls). Every
    /// other event type passes straight through to the normal AppKit dispatch.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else {
            super.sendEvent(event)
            return
        }
        handleScrollWheel(event)
        super.sendEvent(event)
    }

    /// Debounces a trackpad swipe using `NSEvent.phase`, which brackets one
    /// physical two-finger gesture as `.began` → one or more `.changed` →
    /// `.ended`/`.cancelled`. Plain (non-trackpad) scroll wheels report an
    /// empty phase and are deliberately ignored — swiping the notch is a
    /// trackpad/Magic Mouse gesture, matching Dynamic-Island-style UIs.
    private func handleScrollWheel(_ event: NSEvent) {
        switch event.phase {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
            gestureConsumed = false
        case .changed:
            guard !gestureConsumed else { return }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            if abs(accumulatedX) >= abs(accumulatedY) {
                guard abs(accumulatedX) >= Self.swipeThreshold else { return }
                gestureConsumed = true
                viewModel.swiped(accumulatedX > 0 ? .left : .right)
            } else {
                guard abs(accumulatedY) >= Self.swipeThreshold else { return }
                gestureConsumed = true
                viewModel.swiped(accumulatedY > 0 ? .down : .up)
            }
        case .ended, .cancelled:
            accumulatedX = 0
            accumulatedY = 0
            gestureConsumed = false
        default:
            break // .stationary / .mayBegin / momentum-only events: ignored
        }
    }

    // MARK: - Drag-and-drop destination (M2: file shelf)
    //
    // Registered on the *window* itself (`registerForDraggedTypes` above),
    // not a subview, so a drag session carrying files can still be recognized
    // while `ignoresMouseEvents` is `true` (i.e. while `.collapsed`). That
    // flag only suppresses ordinary mouse-event delivery (`sendEvent`'s usual
    // path); AppKit's drag-and-drop machinery resolves a dragging destination
    // through a separate mechanism untouched by it. `NSWindow` conforms to
    // `NSDraggingDestination` once registered, exactly like an `NSView` would.
    //
    // While collapsed, nothing in the current SwiftUI content tree has an
    // `.onDrop` (the shelf's expanded view doesn't exist until the panel
    // expands), so `NotchHostingView.hitTest` returning `nil` outside the
    // tiny physical-notch `interactiveRect` means no view claims the drag
    // either — these window-level overrides are exactly the fallback that
    // catches it there. Once expanded, the shelf's own SwiftUI `.onDrop` sits
    // on a real, hit-testable view covering most of the panel and takes over
    // for drops actually landing on it; these overrides simply stop being
    // reached for those points.
    //
    // All four are pure forwarding to closures `NotchWindowController` sets —
    // this class stays free of any knowledge of `ShelfStore` or the physical
    // notch's screen geometry.
    var onDraggingEntered: ((NSPoint) -> NSDragOperation)?
    var onDraggingUpdated: ((NSPoint) -> NSDragOperation)?
    var onDraggingExited: (() -> Void)?
    var onPerformDragOperation: ((NSPasteboard) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingEntered?(sender.draggingLocation) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender.draggingLocation) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDragOperation?(sender.draggingPasteboard) ?? false
    }
}

/// Hosts `NotchRootView` and enforces click/hover pass-through: only the
/// notch's own currently-visible shape (`NotchViewModel.interactiveRect`) is
/// interactive. Everywhere else in this otherwise fully transparent,
/// panel-sized view is a hole clicks and hover fall straight through, to
/// whatever app the user is actually working in underneath.
final class NotchHostingView: NSHostingView<AnyView> {
    private let viewModel: NotchViewModel
    private var trackingArea: NSTrackingArea?

    init(viewModel: NotchViewModel, rootView: AnyView) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("NotchHostingView does not support NSCoding")
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("NotchHostingView requires a viewModel; use init(viewModel:rootView:)")
    }

    /// Pass-through hit-testing: a point outside the currently-visible black
    /// shape isn't part of the notch UI at all — it's transparent panel over
    /// someone else's window — so returning `nil` there tells AppKit to keep
    /// searching windows *beneath* this one instead of this (otherwise
    /// full-panel-sized) view claiming every click and hover in its frame.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard viewModel.interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// A single `.activeAlways`/`.inVisibleRect` tracking area spanning the
    /// whole view. `.inVisibleRect` means AppKit keeps it in sync with the
    /// view's actual visible bounds on its own, so `bounds` here is only the
    /// initial rect handed to the constructor, not something that needs
    /// manual upkeep beyond re-adding it when this method is called again.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { viewModel.hoverChanged(inside: false) }

    /// One tracking area covers the entire panel (not just the notch shape)
    /// because the shape's own bounds change with `state`; containment against
    /// `interactiveRect` — not the tracking area's extent — is what actually
    /// decides hover, matching the same rect `hitTest` and `NotchRootView`'s
    /// published geometry use.
    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewModel.hoverChanged(inside: viewModel.interactiveRect.contains(point))
    }
}
