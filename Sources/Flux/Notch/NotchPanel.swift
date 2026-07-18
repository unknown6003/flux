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
    }

    /// Never key: taking key focus would (a) steal it from whatever app the
    /// user is typing into and (b) isn't needed — every interaction the notch
    /// supports (hover, click, scroll) works on a non-key panel.
    override var canBecomeKey: Bool { false }

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
