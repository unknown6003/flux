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
        // Shared with `NotchHighlightWindowController`/`LockScreenPresenter`
        // — see `OverlayPanel`'s own doc comment for the recipe this applies.
        // `ignoresMouseEvents: true` here is just a safe starting point
        // matching the state machine's own initial `.collapsed` value;
        // `NotchWindowController` immediately re-syncs this to the live state
        // once the panel is attached/shown.
        OverlayPanel.applyOverlayStyle(to: self, level: .statusBar, ignoresMouseEvents: true)
        acceptsMouseMovedEvents = true
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
    // not a subview — this is the SOLE drag-and-drop path for the whole
    // notch UI, in every state (`.collapsed`, auto-expanding to the shelf, or
    // already `.expanded(.shelf)`). That's deliberate, not incidental: a
    // shelf that's already open used to have its own SwiftUI `.onDrop` for
    // drops landing directly on it — a second, independent
    // `NSDraggingDestination` competing with this window-level one for the
    // same drag session. Two destinations meant AppKit could hand a session
    // back and forth between them mid-drag (a `draggingExited`/
    // `draggingEntered` flicker as the cursor crossed the boundary between
    // the collapsed notch's window-level rect and the expanded view's own
    // hit-testable frame), and a drop right after the collapsed-notch
    // auto-expand could land in the gap and be declined by both. Routing
    // every state through these four overrides — nothing else in the
    // SwiftUI tree claims a drag — removes that race entirely: one
    // destination, no handoff.
    //
    // `ignoresMouseEvents` (`true` while `.collapsed`) only suppresses
    // ordinary mouse-event delivery (`sendEvent`'s usual path); AppKit's
    // drag-and-drop machinery resolves a dragging destination through a
    // separate mechanism untouched by it. `NSWindow` conforms to
    // `NSDraggingDestination` once registered, exactly like an `NSView`
    // would — which is also why `NotchHostingView.hitTest` returning `nil`
    // outside the currently-visible shape doesn't affect drag recognition at
    // all: hit-testing and drag-destination resolution are unrelated AppKit
    // mechanisms.
    //
    // All four are pure forwarding to closures `NotchWindowController` sets —
    // this class stays free of any knowledge of `ShelfStore` or the physical
    // notch's screen geometry. `draggingEntered`/`draggingUpdated` both
    // forward to the same `onDraggingMoved` closure rather than two separate
    // ones: AppKit's contract for both is identical ("what operation for the
    // point right now?"), so `NotchWindowController` making that decision
    // once, in one place, is both simpler and rules out the two ever
    // silently drifting apart in behavior.
    //
    // Open hardware question, flagged for real-hardware QA (see
    // `docs/notch-checklist.md`) — not yet verified on a physical notched
    // Mac: while `.collapsed`, this window is frontmost at `.statusBar`
    // level, and `onDraggingMoved` declines (`[]`) for any point outside
    // `interactiveRect` + `NotchWindowController.dragSlop`. Whether AppKit
    // then retargets that declined drag session to whatever *window* sits
    // beneath this transparent strip — the same pass-through
    // `ignoresMouseEvents` already gives plain mouse events — or whether a
    // frontmost `NSDraggingDestination` that merely declines still blocks
    // the session from reaching what's underneath, is unconfirmed. If it
    // blocks, the accept region needs to shrink further so it stops
    // intercepting drags that were never meant for the notch at all.
    var onDraggingMoved: ((NSPoint) -> NSDragOperation)?
    var onDraggingExited: (() -> Void)?
    var onPerformDragOperation: ((NSPasteboard) -> Bool)?
}

// No `override`: `NSWindow` only implements `NSDraggingDestination`
// informally (an Objective-C category, not declared in its Swift-visible
// class interface), so these four methods aren't overrides of any
// superclass declaration. But AppKit's drag machinery still finds and
// invokes them purely by Objective-C selector — and a plain Swift method
// with no formal protocol conformance anywhere is NOT automatically
// exposed to the Objective-C runtime that lookup relies on. Writing the
// four methods as ordinary members of the `NotchPanel` class body (as a
// previous version of this file did, reasoning only about `override`) would
// silently compile and never once be called: nothing makes them visible by
// selector.
//
// Declaring the conformance here, on this extension, is what actually fixes
// that. `NotchPanel` inherits from `NSPanel`/`NSWindow`, which is an
// `NSObject` subclass, and `NSDraggingDestination` is an `@objc` protocol —
// for an `NSObject` subclass, methods that satisfy an `@objc` protocol's
// requirements are implicitly exposed via `@objc` (and thus reachable by
// selector) purely *because* they're protocol witnesses, with no explicit
// `@objc` attribute needed. The methods themselves must stay physically
// inside this conformance block for that inference to apply to them; moving
// them back onto the class itself (even leaving this `extension NotchPanel:
// NSDraggingDestination {}` as an empty marker elsewhere) does not retroactively
// make the class-body methods @objc.
extension NotchPanel: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingMoved?(sender.draggingLocation) ?? []
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingMoved?(sender.draggingLocation) ?? []
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingExited?()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
