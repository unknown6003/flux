import AppKit
import FluxUI
import SwiftUI

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchPanel.swift and
// Sources/Flux/Support/OverlayPanel.swift. Swipe thresholds, axis latching,
// momentum swallowing, drag forwarding and the hover trigger are unchanged.

@MainActor
enum NotchOverlayStyle {
    static func apply(to panel: NSPanel, level: NSWindow.Level, ignoresMouseEvents: Bool) {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = ignoresMouseEvents
    }

    static func setShowInFullscreen(_ show: Bool, on panel: NSPanel) {
        if show { panel.collectionBehavior.insert(.fullScreenAuxiliary) } else { panel.collectionBehavior.remove(.fullScreenAuxiliary) }
    }
}

/// The fixed-size transparent notch window. It never animates its frame;
/// only the SwiftUI shape inside it morphs. It recognizes two-finger swipes
/// and is the one file-drag destination for every notch state.
@MainActor
final class NotchWindow: NSPanel {
    private let viewModel: NotchViewModel

    var onDraggingMoved: (@MainActor (NSPoint) -> NSDragOperation)?
    var onDraggingExited: (@MainActor () -> Void)?
    var onPerformDragOperation: (@MainActor (NSPasteboard) -> Bool)?

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        NotchOverlayStyle.apply(to: self, level: .statusBar, ignoresMouseEvents: true)
        acceptsMouseMovedEvents = true
        registerForDraggedTypes([.fileURL])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShowInFullscreen(_ show: Bool) { NotchOverlayStyle.setShowInFullscreen(show, on: self) }

    // MARK: Swipe recognition

    static let swipeThreshold: CGFloat = 40
    static let axisDeadZone: CGFloat = 5

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var gestureConsumed = false
    private var gestureAxisIsVertical: Bool?
    private var swallowMomentum = false

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else {
            super.sendEvent(event)
            return
        }
        guard !handleScrollWheel(event) else { return }
        super.sendEvent(event)
    }

    func resetGestureState() {
        accumulatedX = 0
        accumulatedY = 0
        gestureConsumed = false
        swallowMomentum = false
        gestureAxisIsVertical = nil
    }

    private func notchOwnsGesture(vertical: Bool) -> Bool {
        switch viewModel.state {
        case .expanded: return !vertical
        case .activity, .collapsed: return true
        }
    }

    @discardableResult
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        switch event.phase {
        case .began:
            resetGestureState()
            return true
        case .changed:
            guard !gestureConsumed else { return true }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            if gestureAxisIsVertical == nil {
                guard max(abs(accumulatedX), abs(accumulatedY)) >= Self.axisDeadZone else { return true }
                gestureAxisIsVertical = abs(accumulatedY) > abs(accumulatedX)
            }
            guard let vertical = gestureAxisIsVertical else { return true }
            guard notchOwnsGesture(vertical: vertical) else { return false }
            let travelled = vertical ? abs(accumulatedY) : abs(accumulatedX)
            guard travelled >= Self.swipeThreshold else { return true }
            gestureConsumed = true
            swallowMomentum = true
            if vertical {
                viewModel.swiped(accumulatedY > 0 ? .down : .up)
            } else {
                viewModel.swiped(accumulatedX > 0 ? .right : .left)
            }
            return true
        case .ended, .cancelled:
            let owned = gestureConsumed || gestureAxisIsVertical == nil
                || notchOwnsGesture(vertical: gestureAxisIsVertical == true)
            accumulatedX = 0
            accumulatedY = 0
            gestureConsumed = false
            gestureAxisIsVertical = nil
            return owned
        default:
            guard swallowMomentum, !event.momentumPhase.isEmpty else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                swallowMomentum = false
            }
            return true
        }
    }
}

// `NSWindow` has the drag destination methods only as an informal
// Objective-C category. The conformance exposes these witnesses by selector.
extension NotchWindow: NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDraggingMoved?(sender.draggingLocation) ?? []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDraggingMoved?(sender.draggingLocation) ?? []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDraggingExited?()
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onPerformDragOperation?(sender.draggingPasteboard) ?? false
    }
}

/// An exact-size window over the physical notch while collapsed. It gives
/// AppKit a local hover and click target without blocking app toolbars.
@MainActor
final class NotchHoverPanel: NSPanel {
    init(onMove: @escaping @MainActor (NSPoint) -> Void,
         onClick: @escaping @MainActor (NSPoint, NSEvent.ModifierFlags) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        NotchOverlayStyle.apply(to: self, level: .statusBar, ignoresMouseEvents: false)
        acceptsMouseMovedEvents = true
        contentView = NotchHoverTrackingView(onMove: onMove, onClick: onClick)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShowInFullscreen(_ show: Bool) { NotchOverlayStyle.setShowInFullscreen(show, on: self) }
}

@MainActor
private final class NotchHoverTrackingView: NSView {
    private let onMove: @MainActor (NSPoint) -> Void
    private let onClick: @MainActor (NSPoint, NSEvent.ModifierFlags) -> Void
    private var trackingArea: NSTrackingArea?

    init(onMove: @escaping @MainActor (NSPoint) -> Void,
         onClick: @escaping @MainActor (NSPoint, NSEvent.ModifierFlags) -> Void) {
        self.onMove = onMove
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onMove(NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { onMove(NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { onMove(NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { onClick(NSEvent.mouseLocation, event.modifierFlags) }
}

/// Hosts `NotchRootView`. Hit-testing and hover follow the visible shape
/// only, so clicks outside it reach the app underneath.
@MainActor
final class NotchHostingView: NSHostingView<AnyView> {
    private let viewModel: NotchViewModel
    private var trackingArea: NSTrackingArea?

    init(viewModel: NotchViewModel, rootView: AnyView) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @available(*, unavailable)
    required init(rootView: AnyView) { fatalError("init(rootView:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard viewModel.interactiveRect.contains(notchSpacePoint(convert(point, from: superview))) else { return nil }
        return super.hitTest(point)
    }

    private func notchSpacePoint(_ point: NSPoint) -> NSPoint {
        isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { viewModel.hoverChanged(inside: false) }

    private func updateHover(with event: NSEvent) {
        let point = notchSpacePoint(convert(event.locationInWindow, from: nil))
        viewModel.hoverChanged(inside: viewModel.interactiveRect.contains(point))
    }
}
