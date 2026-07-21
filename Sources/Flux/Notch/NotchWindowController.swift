import AppKit
import SwiftUI
import Combine

/// Owns the notch panel's entire lifecycle: creating the shared registry and
/// activity center, building the panel only when a built-in notched screen
/// exists, sizing/positioning it over the physical notch, and tearing it
/// down/rebuilding it whenever the display configuration changes (external
/// monitor connect/disconnect, clamshell close/open).
///
/// This is the one entry point the wiring agent needs: construct it, register
/// widgets on `.registry`, post activities via `.activities`, feed settings
/// into `.viewModel`'s public properties, and call `setEnabled` to match the
/// user's `flux.notch.enabled` preference.
@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    let registry: NotchWidgetRegistry
    let activities: LiveActivityCenter

    /// Supplies now-playing artwork for the activity wings — forwarded
    /// straight to `NotchRootView`. Set by the wiring agent once the Now
    /// Playing service exists; rebuilding the root view on every set is cheap
    /// (SwiftUI reuses the existing panel/window, it just re-renders).
    var artworkProvider: (() -> NSImage?)? {
        didSet { refreshRootView() }
    }

    /// Lets the wiring agent intercept a tap on a live activity's wings —
    /// forwarded straight to `NotchRootView.onActivityTap`. See that
    /// property's doc comment; set once by the wiring agent (e.g. to route
    /// `.menuBarOverflow` into Arrange Mode).
    var onActivityTap: ((LiveActivity.Kind) -> Bool)? {
        didSet { refreshRootView() }
    }

    /// Set by the wiring agent to actually add dropped files to whatever
    /// backs the shelf widget (a `ShelfStore`) and report how many were newly
    /// added, so `handlePerformDrag` can post an accurate `.shelfDrop`
    /// LiveActivity. `NotchWindowController` deliberately never references
    /// the store type directly — that keeps this UI-shell file free of any
    /// dependency on `Services/Shelf`.
    var onShelfDrop: (([URL]) -> Int)?

    /// Slop added around the settled, collapsed `interactiveRect` (the
    /// physical notch's own footprint) when deciding whether an incoming file
    /// drag counts as "over the notch" — generous enough that a drag merely
    /// approaching the notch, not pixel-perfect over the tiny camera-housing
    /// pixels, still triggers the auto-expand.
    private static let dragSlop: CGFloat = 20

    /// Guards `viewModel.dragEntered()` against being called on every one of
    /// a single drag session's many `draggingUpdated` deliveries — set the
    /// first time this session actually triggers the collapsed→auto-expand
    /// path, cleared in `draggingExited`/`performDragOperation` so the
    /// *next* drag session starts fresh. (`dragEntered()` is itself
    /// idempotent — it only acts while `state == .collapsed` — so this isn't
    /// load-bearing for correctness, just for not re-entering the view model
    /// on every pixel of movement.)
    private var dragSessionEntered = false

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView?
    private var isEnabled = false
    /// Mirrors `SettingsStore.notchShowInFullscreen`; applied to `panel` as
    /// soon as one exists, and re-applied to every panel `makePanel()` builds
    /// (a screen change tears down and rebuilds the panel, which would
    /// otherwise silently reset to the `NotchPanel.init` default).
    private var showInFullscreen = true
    private var cancellables = Set<AnyCancellable>()

    /// True once a panel exists AND is actually shown over a real physical
    /// notch — false while disabled, and false when the notch's screen has
    /// been lost (external-only clamshell) even though `panel` itself is
    /// kept alive, merely ordered out, for instant reattachment (see
    /// `resolveScreen`). The global hotkey stays registered even when this
    /// is `false` (so it starts working the instant the notch reappears),
    /// but must not drive a headless expand while it is — see
    /// `hotkeyToggled()`.
    ///
    /// `@Published` (rather than a plain stored property with a `didSet`
    /// closure callback) so `NotchActivityRouter` can observe `$isPresenting`
    /// directly, injected once at construction — replacing the
    /// `onPresentationChanged` closure + `isPresentationAvailable` closure
    /// pair this used to be paired with (see that router's own doc comment
    /// on the M4 code-review fix).
    @Published private(set) var isPresenting = false

    // MARK: - Collapsed-state pass-through monitors (Finding 1)
    //
    // While `.collapsed`, `panel.ignoresMouseEvents` is `true` (see
    // `NotchPanel`'s doc comment for why `hitTest` alone can't achieve
    // pass-through) — which also means the panel itself stops receiving
    // mouse events, so hover/click detection for that state moves here:
    // global monitors see events over every other app; local monitors see
    // events over Flux's own windows (global monitors never fire for
    // own-app events). Installed only while collapsed; torn down the moment
    // the state moves on, the panel is disabled, or the screen is lost.
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    /// Debounces the monitors' (frequent) `mouseMoved` reports the same way
    /// `NotchHostingView.updateHover` debounces its own tracking-area
    /// redeliveries — only an actual inside/outside transition should reach
    /// `viewModel.hoverChanged`.
    private var lastMonitoredInside = false

    init() {
        let registry = NotchWidgetRegistry()
        let activities = LiveActivityCenter()
        self.registry = registry
        self.activities = activities
        self.viewModel = NotchViewModel(registry: registry, activities: activities)

        // The only thing that can change which screen (if any) is the
        // built-in notched one: a monitor connects/disconnects, or the lid
        // closes/opens over a clamshell setup. Both fire this notification.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.resolveScreen() }
            .store(in: &cancellables)

        // Keeps the panel's `ignoresMouseEvents`/monitor setup in lockstep
        // with the state machine — a state change while already presenting
        // is the common case this reacts to (screen-change-driven syncing
        // is handled explicitly in `resolveScreen`, since that's a re-sync
        // of `isPresenting` itself, not just `state`).
        viewModel.$state
            .sink { [weak self] state in self?.updatePassThrough(for: state) }
            .store(in: &cancellables)
    }

    deinit {
        // `NSEvent.removeMonitor` is safe to call from `deinit` — it's a
        // plain class method taking the opaque token, not a call on `self`.
        [globalMoveMonitor, localMoveMonitor, globalClickMonitor, localClickMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
    }

    /// Turns the whole notch feature on/off. Disabling tears the panel down
    /// completely (not just orders it out), so a disabled notch costs
    /// nothing: no hidden window, no SwiftUI body still attached and ticking.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            resolveScreen()
        } else {
            // `isPresenting` (and the monitors it gates) go first so the
            // `forceCollapse()` below — which republishes `.collapsed` on
            // `viewModel.$state` — can't turn around and reinstall them on a
            // panel that's about to be torn down.
            isPresenting = false
            removeCollapsedMonitors()
            // Force the state machine to `.collapsed` *before* tearing the
            // panel down. A plain `collapse()` could re-enter `.activity` if
            // one happened to be current, leaving an expanded widget's
            // `didDismiss()` never called even though its panel just
            // vanished — `forceCollapse()` guarantees the exactly-once
            // willPresent/didDismiss pairing holds even on the way out.
            viewModel.forceCollapse()
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
        }
    }

    /// Mirrors `SettingsStore.notchShowInFullscreen` into the live panel (and
    /// remembers it for the next panel `makePanel()` builds, e.g. after a
    /// screen change).
    func setShowInFullscreen(_ show: Bool) {
        showInFullscreen = show
        panel?.setShowInFullscreen(show)
    }

    // MARK: - Hotkey

    /// Entry point for the global notch-toggle hotkey. The hotkey stays
    /// registered even when there's no built-in notched screen at all
    /// (external-display clamshell, non-notch Mac) so it starts working
    /// again the instant one reappears — but firing straight into
    /// `viewModel.hotkeyToggled()` while `isPresenting` is `false` would
    /// expand/collapse a state machine nothing is showing: an invisible
    /// widget (e.g. Now Playing) would start running for zero visible
    /// benefit. This is the single gate that keeps a headless expand from
    /// ever happening; every other input (hover, click, swipe) already only
    /// reaches `viewModel` through the panel itself, which can't receive
    /// them unless it's presenting.
    func hotkeyToggled() {
        guard isPresenting else { return }
        viewModel.hotkeyToggled()
    }

    // MARK: - Screen resolution

    /// Finds (or loses) the built-in notched screen and reflects that in the
    /// panel: create-and-show if one exists and there's no panel yet,
    /// reposition if one already exists, or order out (without discarding
    /// state) if none currently qualifies — e.g. a clamshell Mac running on
    /// an external-only setup. Ordering out rather than tearing down means
    /// returning to the built-in display (opening the lid) reattaches
    /// instantly, with the notch UI's state exactly as it was left.
    ///
    /// Losing the screen also force-collapses: with `isPresenting` about to
    /// go `false`, there is by definition no panel left to show a widget or
    /// live activity in, so anything still `.expanded`/`.activity` at that
    /// moment must be told to stop the same way `setEnabled(false)` already
    /// does — otherwise a widget could keep polling/ticking headlessly until
    /// the notch's screen comes back.
    private func resolveScreen() {
        guard isEnabled else { return }
        guard let screen = NSScreen.builtInNotchedScreen, let notchRect = screen.notchRect else {
            isPresenting = false
            removeCollapsedMonitors()
            panel?.orderOut(nil)
            viewModel.forceCollapse()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        hostingView?.rootView = makeRootView(notchSize: notchRect.size)
        position(panel, on: screen, notchRect: notchRect)
        panel.orderFrontRegardless()
        isPresenting = true
        // A state-machine *change* re-syncs `ignoresMouseEvents`/monitors on
        // its own via the `viewModel.$state` sink installed in `init`, but
        // `isPresenting` flipping true here isn't itself a state change (the
        // state could easily already be `.collapsed` from before the screen
        // was lost), so this explicit call is what actually arms the
        // monitors for a freshly-(re)presented panel.
        updatePassThrough(for: viewModel.state)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(viewModel: viewModel)
        panel.setShowInFullscreen(showInFullscreen)
        let hosting = NotchHostingView(viewModel: viewModel, rootView: makeRootView(notchSize: .zero))
        panel.contentView = hosting
        hostingView = hosting
        wireDragHandlers(to: panel)
        return panel
    }

    private func makeRootView(notchSize: CGSize) -> AnyView {
        AnyView(NotchRootView(viewModel: viewModel, notchSize: notchSize,
                              artworkProvider: artworkProvider, onActivityTap: onActivityTap))
    }

    private func refreshRootView() {
        guard let hostingView, let notchSize = NSScreen.builtInNotchedScreen?.notchRect?.size else { return }
        hostingView.rootView = makeRootView(notchSize: notchSize)
    }

    /// Sizes the panel to the fixed panel bounds (`NotchMetrics.panelBounds`
    /// — wide/tall enough for the widest/tallest widget, plus room reserved
    /// for the future Duo agent widget) and centers it, top-anchored, on the
    /// physical notch. This frame never changes with `viewModel.state` — only
    /// the SwiftUI content inside grows/shrinks, to its own smaller per-widget
    /// size — so repositioning only has to happen when the screen itself
    /// changes.
    private func position(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let bounds = NotchMetrics.panelBounds(for: notchRect.width)
        let origin = NSPoint(x: notchRect.midX - bounds.width / 2, y: screen.frame.maxY - bounds.height)
        panel.setFrame(NSRect(origin: origin, size: bounds), display: true)
    }

    // MARK: - Collapsed-state pass-through (Finding 1)

    /// The single place `panel.ignoresMouseEvents` is decided, and the
    /// monitors that stand in for hit-testing while it's `true`. See
    /// `NotchPanel`'s doc comment for why `hitTest` returning `nil` can't do
    /// this on its own.
    ///
    /// Note this intentionally does *not* cover the two-finger swipe gesture
    /// `NotchPanel.sendEvent` recognizes (`swiped(.down)` opening from
    /// `.collapsed`) — `ignoresMouseEvents` suppresses scroll-wheel delivery
    /// to the panel exactly like every other mouse event, so that gesture is
    /// only live while `.activity`/`.expanded`. Hover and click already cover
    /// opening from collapsed, so this is a narrower gesture surface, not a
    /// silent break of the primary open paths.
    private func updatePassThrough(for state: NotchState) {
        guard let panel, isPresenting else {
            removeCollapsedMonitors()
            return
        }
        switch state {
        case .collapsed:
            panel.ignoresMouseEvents = true
            installCollapsedMonitors()
        case .activity, .expanded:
            panel.ignoresMouseEvents = false
            removeCollapsedMonitors()
        }
    }

    /// No-op if already installed — callers (the `viewModel.$state` sink,
    /// `resolveScreen`) can call this freely without risking doubled monitors.
    private func installCollapsedMonitors() {
        guard globalMoveMonitor == nil else { return }
        lastMonitoredInside = false

        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            // Captured synchronously — matching `MenuBarManager`'s own
            // outside-click monitor — since global-monitor handlers aren't
            // guaranteed to run on the main actor and `NSEvent.mouseLocation`
            // could otherwise read a slightly later position after the hop.
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMonitoredMove(at: location) }
        }
        // Global monitors never fire for events targeting Flux's own
        // windows — a local monitor is the only way to see mouse-moved
        // events while, e.g., the Settings window has focus.
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMonitoredMove(at: NSEvent.mouseLocation)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMonitoredClick(at: location) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMonitoredClick(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func removeCollapsedMonitors() {
        [globalMoveMonitor, localMoveMonitor, globalClickMonitor, localClickMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        globalClickMonitor = nil
        localClickMonitor = nil
        lastMonitoredInside = false
    }

    /// `NSEvent.mouseLocation` is already in global screen coordinates — the
    /// same space `NSScreen.notchRect` is published in — so, unlike the
    /// hit-test path `NotchHostingView` uses while presenting non-collapsed,
    /// no window/view coordinate conversion is needed here at all.
    private func handleMonitoredMove(at location: NSPoint) {
        guard let rect = NSScreen.builtInNotchedScreen?.notchRect else { return }
        let inside = rect.contains(location)
        guard inside != lastMonitoredInside else { return }
        lastMonitoredInside = inside
        viewModel.hoverChanged(inside: inside)
    }

    /// A click landing on the notch while collapsed would otherwise be lost
    /// entirely — `ignoresMouseEvents` means `NotchRootView`'s own
    /// `onTapGesture` never sees it. Global monitors can't consume/swallow
    /// the event they observe, which is fine here: the physical notch has no
    /// real pixels for another app to receive that same click instead.
    private func handleMonitoredClick(at location: NSPoint) {
        guard let rect = NSScreen.builtInNotchedScreen?.notchRect, rect.contains(location) else { return }
        viewModel.clicked()
    }

    // MARK: - Drag-and-drop, collapsed and expanded (M2: file shelf)

    /// Points `panel`'s window-level drag-destination closures (see
    /// `NotchPanel`'s own doc comment) back at this controller. Called once,
    /// right after each panel is built — a fresh panel is created on every
    /// screen change, so this has to be re-wired there rather than only once.
    private func wireDragHandlers(to panel: NotchPanel) {
        panel.onDraggingMoved = { [weak self] location in self?.handleDraggingUpdate(at: location) ?? [] }
        panel.onDraggingExited = { [weak self] in self?.handleDraggingExited() }
        panel.onPerformDragOperation = { [weak self] pasteboard in self?.handlePerformDrag(pasteboard) ?? false }
    }

    /// Pure predicate behind `handleDraggingUpdate`'s accept/decline
    /// decision — split out so `--selftest` can drive every
    /// state/geometry/enabled combination headlessly, without a real window,
    /// screen, or drag session. `pointInNotch` is pre-computed by the caller
    /// against whichever rect is actually relevant for `state` (see
    /// `handleDraggingUpdate`): this function has no window-coordinate
    /// geometry of its own to test against.
    ///
    /// This is the SOLE gate for accepting a file drag, in either of the two
    /// states a drag can ever be accepted in:
    /// - `.collapsed`: only if the shelf widget is enabled *and* the point is
    ///   over the notch (with slop) — an incoming drag must not auto-expand
    ///   to a widget that's off, or before it's actually over the notch.
    /// - `.expanded(.shelf)`: only if the point is still within the shelf's
    ///   own bounds — this is what keeps the window accepting *after* a
    ///   `.collapsed` drag auto-expanded it, so `performDragOperation` is
    ///   actually delivered instead of the session being declined the
    ///   instant the state flips out from under it.
    ///
    /// Every other state (a live activity, or a different expanded widget)
    /// declines unconditionally — an incoming drag must never preempt
    /// something else the user is already looking at.
    static func shouldAcceptDrag(state: NotchState, pointInNotch: Bool, shelfEnabled: Bool) -> Bool {
        switch state {
        case .collapsed:
            return shelfEnabled && pointInNotch
        case .expanded(.shelf):
            return pointInNotch
        default:
            return false
        }
    }

    /// Shared by `draggingEntered`/`draggingUpdated` (now unified into
    /// `NotchPanel.onDraggingMoved` — see that property's doc comment for
    /// why). Computes the one piece of geometry `shouldAcceptDrag` needs —
    /// whether the drag's point falls inside whichever rect matters for the
    /// *current* state — then defers the actual accept/decline call to that
    /// pure function.
    ///
    /// Reuses `viewModel.interactiveRect` rather than re-deriving the
    /// physical notch's screen geometry from `NSScreen`: while `.collapsed`
    /// (and settled — see `NotchRootView.updateInteractiveRect`), that rect
    /// *is* exactly the physical notch's footprint; while `.expanded(.shelf)`,
    /// it's the full open shelf panel's bounds. Converting the drag's
    /// window-space location into that same space and testing containment
    /// (with slop only in the collapsed case) is both correct and avoids a
    /// second, easily-drifting copy of the same geometry.
    private func handleDraggingUpdate(at windowLocation: NSPoint) -> NSDragOperation {
        guard let hostingView else { return [] }
        let localPoint = hostingView.convert(windowLocation, from: nil)
        let shelfEnabled = registry.enabledWidgets.contains { $0.id == .shelf }

        let pointInNotch: Bool
        switch viewModel.state {
        case .collapsed:
            pointInNotch = viewModel.interactiveRect.insetBy(dx: -Self.dragSlop, dy: -Self.dragSlop).contains(localPoint)
        case .expanded(.shelf):
            pointInNotch = viewModel.interactiveRect.contains(localPoint)
        default:
            pointInNotch = false
        }

        guard Self.shouldAcceptDrag(state: viewModel.state, pointInNotch: pointInNotch, shelfEnabled: shelfEnabled) else {
            return []
        }

        if viewModel.state == .collapsed, !dragSessionEntered {
            dragSessionEntered = true
            viewModel.dragEntered()
        }
        return .copy
    }

    /// The drag session left without a drop landing — resets the
    /// once-per-session guard alongside telling the view model, so the
    /// *next* session (collapsed→hover-in again, say) starts fresh.
    private func handleDraggingExited() {
        dragSessionEntered = false
        viewModel.dragExited()
    }

    /// Reads dropped file URLs off the pasteboard, hands them to the wiring
    /// agent's `onShelfDrop` to actually add them to the shelf, and — on a
    /// successful add — posts a brief `.shelfDrop` LiveActivity so the user
    /// gets feedback even if the panel doesn't stay open (e.g. the cursor
    /// immediately moves off after the drop, closing an auto-expanded shelf
    /// via the usual hover-out path). Gated on the shelf still being enabled
    /// — `handleDraggingUpdate` already requires this to have accepted the
    /// drag in the first place, but the widget could in principle have been
    /// disabled in the narrow window between accept and drop.
    private func handlePerformDrag(_ pasteboard: NSPasteboard) -> Bool {
        defer {
            dragSessionEntered = false
            viewModel.dragCompleted()
        }
        guard registry.enabledWidgets.contains(where: { $0.id == .shelf }) else { return false }
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        let added = onShelfDrop?(urls) ?? 0
        guard added > 0 else { return false }

        activities.post(LiveActivity(
            kind: .shelfDrop,
            leading: .icon(systemName: "tray.and.arrow.down.fill"),
            trailing: .text("Added \(added)"),
            duration: 2.5,
            priority: 120))
        return true
    }
}
