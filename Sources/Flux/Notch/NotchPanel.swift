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
    /// Set once a gesture has fired a swipe, so continuing to scroll past the
    /// threshold within the *same* physical gesture doesn't queue up several
    /// more swipes — one physical gesture is one logical swipe.
    private var gestureConsumed = false

    /// The axis this gesture belongs to, latched ONCE per gesture and never
    /// re-evaluated until the next `.began`.
    ///
    /// Recomputing it per frame from the running accumulators — which a first
    /// pass did — lets ownership flip mid-gesture, both ways. A vertical
    /// scroll with a little horizontal drift forwards frames to the inner
    /// list until `|x|` overtakes `|y|`, at which point the whole accumulated
    /// X is already past the threshold and the page flips instantly under the
    /// list the user was scrolling. And the noisy opening frames of a
    /// horizontal swipe, where `|y| > |x|`, leak into the widget being left.
    private var gestureAxisIsVertical: Bool?

    /// Whether momentum frames trailing the current gesture should still be
    /// swallowed. Kept apart from `gestureConsumed`, which is now strictly
    /// per-gesture: conflating them let a claim that ended while the panel
    /// was non-interactive (an `.activity` dismiss flips
    /// `ignoresMouseEvents`, so `.ended` never arrives) freeze the flag true
    /// and swallow a later gesture outright.
    private var swallowMomentum = false

    /// Movement required before the axis is latched. Small enough to be
    /// imperceptible, large enough that the first frame's noise doesn't
    /// decide the gesture.
    private static let axisDeadZone: CGFloat = 5

    /// Intercepts `scrollWheel` ahead of normal event dispatch so a two-finger
    /// gesture over the notch cycles/opens/closes it. Every other event type
    /// passes straight through to the normal AppKit dispatch.
    ///
    /// ## Only the gestures the notch actually uses are claimed
    ///
    /// M12 claimed EVERY phase-bearing gesture, on the reasoning that a
    /// trackpad gesture over this panel is always a notch gesture. That was
    /// wrong and broke scrolling outright: four widgets host a `ScrollView`,
    /// and a scroll up past the 40pt threshold both failed to reach the list
    /// and collapsed the drawer.
    ///
    /// The axes don't actually collide. While `.expanded` the notch's own
    /// gesture is HORIZONTAL (cycle pages) and the content scrolls
    /// VERTICALLY — so vertical gestures are simply never claimed there, and
    /// horizontal ones are harmless to a vertical `ScrollView` even before
    /// the claim lands. While `.collapsed` the panel ignores mouse events
    /// entirely, and `.activity` has no scrollable content, so both axes stay
    /// available to the notch in those states.
    ///
    /// ## A claimed gesture is still swallowed whole
    /// This used to call `super.sendEvent(event)` unconditionally, so every
    /// swipe did two things at once: it switched the page, AND it scrolled
    /// whatever was inside the widget. Three of the five widgets (Shelf,
    /// Calendar, Clipboard) host a `ScrollView`, so swiping between
    /// pages visibly scrolled the list you were swiping away from — and,
    /// worse, delivered scroll events into a SwiftUI subtree that the very
    /// same gesture had just torn down, since `viewModel.swiped(_:)` runs
    /// synchronously on the line above. Swiping quickly stacks those
    /// teardowns (the outgoing subtree stays alive for the ~0.42s spring),
    /// so there is always a half-dead tree for a stale-target scroll to land
    /// in — the "crashes when I switch pages fast" report.
    ///
    /// Once a gesture is claimed, the REST of it is swallowed — its remaining
    /// `changed` frames, its `ended`, and the momentum that trails it. That
    /// part is load-bearing and unchanged: `viewModel.swiped(_:)` runs
    /// synchronously during recognition and tears the outgoing widget's
    /// subtree down, so continuing to deliver that gesture's events into it
    /// is the fast-page-switch crash.
    ///
    /// A plain mouse wheel reports neither phase and is never claimed, so
    /// wheel-scrolling a widget's list always works.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else {
            super.sendEvent(event)
            return
        }
        guard !handleScrollWheel(event) else { return }
        super.sendEvent(event)
    }

    /// Clears all in-flight gesture state.
    ///
    /// Called by `NotchWindowController` whenever `ignoresMouseEvents` flips,
    /// because that is exactly when a gesture can be cut off mid-flight: an
    /// `.activity` swipe-up dismisses the activity, the state machine lands
    /// on `.collapsed`, the panel stops receiving events, and this gesture's
    /// `.ended` never arrives. Without this reset the accumulators and flags
    /// stay frozen, and the next gesture — whose `.began` was also eaten
    /// while collapsed — gets swallowed wholesale.
    func resetGestureState() {
        accumulatedX = 0
        accumulatedY = 0
        gestureConsumed = false
        swallowMomentum = false
        gestureAxisIsVertical = nil
    }

    /// Whether a gesture along `axis` is one the notch itself acts on in the
    /// current state — i.e. whether claiming it is correct.
    private func notchOwnsGesture(vertical: Bool) -> Bool {
        switch viewModel.state {
        case .expanded:
            // Horizontal cycles pages; vertical belongs to whatever the
            // widget is showing, which is the only way its list can scroll.
            return !vertical
        case .activity:
            // Nothing here scrolls, and both axes mean something: down
            // expands, up dismisses the activity, left/right cycle them.
            return true
        case .collapsed:
            // Unreachable in practice — `ignoresMouseEvents` is `true` while
            // collapsed, so no scroll event reaches this panel at all, and
            // there is no scroll monitor standing in for it the way there is
            // for hover and clicks. Kept exhaustive rather than folded into
            // the case above so that stays visible.
            return true
        }
    }

    /// Debounces a trackpad swipe using `NSEvent.phase`, which brackets one
    /// physical two-finger gesture as `.began` → one or more `.changed` →
    /// `.ended`/`.cancelled`. Plain (non-trackpad) scroll wheels report an
    /// empty phase and are deliberately ignored — swiping the notch is a
    /// trackpad/Magic Mouse gesture, matching Dynamic-Island-style UIs.
    ///
    /// Recognises the gesture and reports whether it belongs to the notch —
    /// `true` meaning `sendEvent` must not also deliver it to the content.
    @discardableResult
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        switch event.phase {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
            gestureConsumed = false
            swallowMomentum = false
            gestureAxisIsVertical = nil
            // Swallowed until the axis latches — see `gestureAxisIsVertical`.
            // A gesture this panel is going to claim must never have
            // delivered anything to the content, or the inner scroll view is
            // started and then never sent its `ended`.
            return true
        case .changed:
            // Everything after the claim is swallowed: recognition already
            // tore the outgoing subtree down.
            guard !gestureConsumed else { return true }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY

            if gestureAxisIsVertical == nil {
                guard max(abs(accumulatedX), abs(accumulatedY)) >= Self.axisDeadZone else {
                    return true   // still undecided; keep swallowing
                }
                gestureAxisIsVertical = abs(accumulatedY) > abs(accumulatedX)
            }
            guard let vertical = gestureAxisIsVertical else { return true }

            // Not ours on this axis in this state — hand this and every
            // later frame of the gesture to the content.
            guard notchOwnsGesture(vertical: vertical) else { return false }

            let travelled = vertical ? abs(accumulatedY) : abs(accumulatedX)
            // Ours, but not yet decisive: still swallowed, so a gesture that
            // never reaches the threshold leaks nothing either.
            guard travelled >= Self.swipeThreshold else { return true }
            gestureConsumed = true
            swallowMomentum = true
            if vertical {
                viewModel.swiped(accumulatedY > 0 ? .down : .up)
            } else {
                // The two axes MUST use the same sign convention, and this
                // one didn't. Under natural scrolling `scrollingDelta`
                // follows the fingers on both axes: down is `deltaY > 0`,
                // right is `deltaX > 0`. The vertical line honours that
                // (fingers down expands, which is the shipped, QA-verified
                // behaviour); the horizontal one used to read `deltaX > 0`
                // as `.left`, i.e. fingers-right advancing the cycle. Since
                // `.left` maps to `cycle(forward:)`, flicking a page away
                // walked the configured order BACKWARDS — which is what
                // "the cycle order doesn't match what I set" actually was.
                viewModel.swiped(accumulatedX > 0 ? .right : .left)
            }
            return true
        case .ended, .cancelled:
            let owned = gestureConsumed || gestureAxisIsVertical == nil
                || notchOwnsGesture(vertical: gestureAxisIsVertical == true)
            accumulatedX = 0
            accumulatedY = 0
            // Strictly per-gesture now. `swallowMomentum` carries the claim
            // forward to the momentum tail instead.
            gestureConsumed = false
            gestureAxisIsVertical = nil
            return owned
        default:
            // Momentum frames report an empty `phase`, which is also what a
            // plain mouse wheel reports — so the momentum test is what stops
            // one trackpad swipe suppressing every later wheel scroll.
            guard swallowMomentum, !event.momentumPhase.isEmpty else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                swallowMomentum = false
            }
            return true
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
        guard viewModel.interactiveRect.contains(notchSpacePoint(convert(point, from: superview))) else { return nil }
        return super.hitTest(point)
    }

    /// Maps a point in this view's own AppKit coordinate space into the space
    /// `NotchViewModel.interactiveRect` is published in.
    ///
    /// `interactiveRect` is written by `NotchRootView` in SwiftUI's
    /// top-left-origin space (y grows downward). An `NSView`'s space is
    /// bottom-left-origin unless the view reports `isFlipped` — and whether
    /// `NSHostingView` does is an undocumented implementation detail of
    /// SwiftUI's AppKit bridge, not something to bet the notch's entire
    /// click/hover surface on. Branching on `isFlipped` is correct either
    /// way, and collapses to a no-op when it's already `true`.
    private func notchSpacePoint(_ point: NSPoint) -> NSPoint {
        isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
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
    ///
    /// Since M12 this is only a *second opinion*: `NotchWindowController`'s
    /// global/local `.mouseMoved` monitors drive hover in every state,
    /// because AppKit doesn't reliably deliver `mouseMoved:` to a
    /// non-activating panel that never becomes key (see that controller's own
    /// `globalMoveMonitor` doc comment). `NotchViewModel.hoverChanged` is
    /// idempotent, so the two agreeing costs nothing.
    private func updateHover(with event: NSEvent) {
        let point = notchSpacePoint(convert(event.locationInWindow, from: nil))
        viewModel.hoverChanged(inside: viewModel.interactiveRect.contains(point))
    }
}
