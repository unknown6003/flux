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
    var onShelfDrop: (([URL]) -> ShelfDropResult)?

    /// What a drop actually achieved. Two numbers, because they answer
    /// different questions and conflating them made the notch lie in one
    /// direction or the other (Codex PR13 finding).
    ///
    /// `accepted` decides whether `performDragOperation` returns `true` — a
    /// large file or a folder copies on a background task, and reporting
    /// those as zero made macOS play its drag-snaps-back rejection animation
    /// over a drop that was working fine. But `accepted` must NOT be what the
    /// confirmation wing claims, since a background copy can still fail (the
    /// source vanishes, permissions change, the disk fills) — announcing
    /// "Added 3" for items that never arrive is the same lie pointing the
    /// other way. `ready` is the count actually on the shelf right now.
    struct ShelfDropResult {
        let accepted: Int
        let ready: Int

        /// Named `declined` rather than `none`: `??` has two overloads, and
        /// `x ?? .none` is ambiguous between this member and `Optional.none`
        /// — which one the solver picks decides whether the result is
        /// optional at all. Not a name to leave to chance.
        static let declined = ShelfDropResult(accepted: 0, ready: 0)
    }

    /// Builds the context menu a right-click on the notch pops up. Set once
    /// by the wiring agent (`AppDelegate`), which is the only layer that
    /// knows about Settings, the widget toggles, and quitting — this
    /// controller stays a pure UI shell and just decides *when* a right-click
    /// counts as being on the notch. Nil (unset) means right-click does
    /// nothing, which is also the correct behaviour in `--selftest`/snapshot
    /// runs where no menu targets exist.
    var menuProvider: (() -> NSMenu)?

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
    /// A tiny, exact-size trigger window used while the main panel is
    /// collapsed. The main panel must ignore mouse events in that state so
    /// app toolbars beneath its fixed envelope stay usable, but a separate
    /// window over only the physical housing gives AppKit a reliable local
    /// hover target even when a global mouse monitor misses the first move.
    private var collapsedHoverPanel: NotchHoverPanel?
    private var isEnabled = false
    /// A screen can report its safe-area data a moment after the app starts
    /// (especially when Flux launches at login or the lid is opening). A
    /// short bounded retry keeps that transient nil from leaving the notch
    /// hidden until the next display-change notification.
    private var screenResolutionTask: Task<Void, Never>?
    /// Mirrors `SettingsStore.notchShowInFullscreen`; applied to `panel` as
    /// soon as one exists, and re-applied to every panel `makePanel()` builds
    /// (a screen change tears down and rebuilds the panel, which would
    /// otherwise silently reset to the `NotchPanel.init` default).
    private var showInFullscreen = true
    /// Mirrors `SettingsStore.appearance` into the notch panel.
    private var appearanceMode: FluxAppearance = .dark
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

    // MARK: - Pointer monitors
    //
    // The fixed panel is pass-through while collapsed and whenever the
    // pointer is outside the visible shape. Inside an open activity/widget,
    // it accepts events so SwiftUI controls still work. Global monitors see
    // events over every other app; local monitors see events over Flux's own
    // windows (global monitors never fire for own-app events), so both are
    // needed to cover the screen.
    //
    // ## M12 hover-reliability fix: move monitors run in EVERY state
    // These used to be installed only while `.collapsed`, on the theory that
    // the panel's own `NSTrackingArea` (see `NotchHostingView`) covers hover
    // once `ignoresMouseEvents` goes back to `false` inside the visible shape.
    // It doesn't, reliably:
    // AppKit only guarantees `mouseMoved:` delivery to the KEY window, and
    // this panel is a `.nonactivatingPanel` that deliberately refuses key
    // (`NotchPanel.canBecomeKey` is `false`) in an app that is almost never
    // frontmost. So in every state where the notch was already showing
    // something — most commonly `.activity`, i.e. any time a live activity
    // wing was up — hovering it did nothing at all, while hovering the same
    // pixels with nothing showing worked fine. That intermittency is exactly
    // the "works about half the time" symptom. Driving hover from these
    // monitors in all states removes the dependency on tracking-area
    // delivery entirely; the tracking area stays as a harmless second
    // opinion (`hoverChanged` is idempotent).
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var localRightClickMonitor: Any?
    /// A low-rate cursor poll backs up AppKit's global/local mouse monitors.
    /// Those monitors can be absent (for example when macOS has not granted
    /// Input Monitoring yet), and neither monitor is guaranteed to report a
    /// stationary cursor when a panel is shown underneath it. Polling the
    /// cursor position keeps hover deterministic without putting another
    /// mouse-active window over an app's toolbar.
    private var hoverPollTimer: Timer?
    /// Left-click monitors, unlike the two pairs above, stay COLLAPSED-ONLY:
    /// in every other state the panel itself receives the click and
    /// `NotchRootView`'s own `onTapGesture` handles it. While collapsed, the
    /// monitor covers the forgiving side band and a hidden exact trigger;
    /// `NotchHoverPanel` owns the exact physical-notch click.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    /// See `installPointerMonitors()` — idempotence can't be keyed on a
    /// monitor token, since `addGlobalMonitorForEvents` may return nil.
    private var pointerMonitorsInstalled = false
    /// See `installCollapsedClickMonitors()`.
    private var collapsedClickMonitorsInstalled = false
    /// Set while the right-click context menu is tracking. `NSMenu.popUp`
    /// runs its own modal event loop, during which the cursor necessarily
    /// leaves the notch to reach the menu items — without this the hover-out
    /// timer would collapse the panel out from under the open menu.
    private var isShowingMenu = false {
        // Mirrored onto the view model so the panel's own tracking area is
        // covered too, not just these monitors — see
        // `NotchViewModel.suppressHover`.
        didSet { viewModel.suppressHover = isShowingMenu }
    }

    /// Horizontal slop added to the collapsed notch's own footprint when
    /// deciding whether the pointer counts as "over the notch".
    ///
    /// ## M12 hover-reliability fix, part two
    /// `interactiveRect` while collapsed is the *physical* notch — the camera
    /// housing, which has no pixels and over which macOS hides the cursor
    /// entirely. Users therefore can't see what they're aiming at and land
    /// just beside or just below it, which read as a miss. A few points of
    /// slop makes the target match where people actually aim. It costs
    /// nothing in pass-through terms: these monitors are passive observers
    /// that never consume the events they see.
    private static let hoverSlopX: CGFloat = 24

    /// Clicks use a smaller horizontal band than hover. It is still twice as
    /// forgiving as the old target, while keeping the active region inside
    /// the menu-bar strip and away from unrelated app controls.
    private static let clickSlopX: CGFloat = 16

    /// Vertical slop, applied DOWNWARD only (the notch is flush with the top
    /// of the screen, so there is no "above" to extend into). This direction
    /// reaches into another app's window, so it stays inside the menu-bar
    /// strip's own visual neighbourhood while covering the common aim error
    /// below an invisible camera housing.
    private static let hoverSlopBelow: CGFloat = 20

    /// The polling fallback runs often enough to feel immediate but keeps the
    /// main run loop and battery cost tiny compared with a display refresh.
    private static let hoverPollInterval: TimeInterval = 1.0 / 30.0

    /// Slop for the already-open shape. Small: the open panel is a large,
    /// visible target that needs no help being hit — this only keeps a
    /// cursor tracing the panel's own edge from flickering the hover-out
    /// timer on and off.
    private static let openHoverSlop: CGFloat = 4

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
            .sink { [weak self] _ in self?.screenParametersChanged() }
            .store(in: &cancellables)

        // `didChangeScreenParameters` is not guaranteed after a login-item
        // launch, so activation is a second cheap chance to attach after the
        // window server has finished publishing its screen list.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleScreenResolutionRetries() }
            .store(in: &cancellables)

        // Keeps the panel's `ignoresMouseEvents`/monitor setup in lockstep
        // with the state machine — a state change while already presenting
        // is the common case this reacts to (screen-change-driven syncing
        // is handled explicitly in `resolveScreen`, since that's a re-sync
        // of `isPresenting` itself, not just `state`).
        viewModel.$state
            .sink { [weak self] state in self?.updatePassThrough(for: state) }
            .store(in: &cancellables)

        // The root view publishes a union rect during its spring transition
        // and the settled shape afterwards. Re-evaluate the panel's mouse
        // capture whenever that rect changes, even if the pointer is still —
        // a low-battery activity can appear underneath a stationary cursor.
        viewModel.$interactiveRect
            .sink { [weak self] _ in self?.updateMouseCapture(at: NSEvent.mouseLocation) }
            .store(in: &cancellables)
    }

    deinit {
        screenResolutionTask?.cancel()
        hoverPollTimer?.invalidate()
        // `NSEvent.removeMonitor` is safe to call from `deinit` — it's a
        // plain class method taking the opaque token, not a call on `self`.
        [globalMoveMonitor, localMoveMonitor, globalRightClickMonitor, localRightClickMonitor,
         globalClickMonitor, localClickMonitor]
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
            scheduleScreenResolutionRetries()
        } else {
            screenResolutionTask?.cancel()
            screenResolutionTask = nil
            // `isPresenting` (and the monitors it gates) go first so the
            // `forceCollapse()` below — which republishes `.collapsed` on
            // `viewModel.$state` — can't turn around and reinstall them on a
            // panel that's about to be torn down.
            isPresenting = false
            removePointerMonitors()
            removeCollapsedClickMonitors()
            // Force the state machine to `.collapsed` *before* tearing the
            // panel down. A plain `collapse()` could re-enter `.activity` if
            // one happened to be current, leaving an expanded widget's
            // `didDismiss()` never called even though its panel just
            // vanished — `forceCollapse()` guarantees the exactly-once
            // willPresent/didDismiss pairing holds even on the way out.
            viewModel.forceCollapse()
            collapsedHoverPanel?.orderOut(nil)
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
        }
    }

    /// Re-resolve immediately for a real display change, then keep trying for
    /// a short bounded window of about ten seconds. AppKit sometimes posts
    /// the notification before the auxiliary notch rectangles have settled,
    /// so one synchronous read is not enough to make the panel reliable at
    /// login or lid-open time.
    private func screenParametersChanged() {
        guard isEnabled else { return }
        resolveScreen()
        scheduleScreenResolutionRetries()
    }

    /// Retries screen discovery at increasing, short delays. The task stops
    /// as soon as a notched built-in screen is presenting, and cancellation
    /// on disable prevents a late retry from resurrecting a turned-off panel.
    private func scheduleScreenResolutionRetries() {
        screenResolutionTask?.cancel()
        guard isEnabled else { return }
        let delays: [TimeInterval] = [0.05, 0.20, 0.60, 1.20, 2.50, 5.00]
        screenResolutionTask = Task { @MainActor [weak self] in
            for delay in delays {
                guard !Task.isCancelled else { return }
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.resolveScreen()
                if self.isPresenting { return }
            }
        }
    }

    /// Mirrors `SettingsStore.notchShowInFullscreen` into the live panel (and
    /// remembers it for the next panel `makePanel()` builds, e.g. after a
    /// screen change).
    func setShowInFullscreen(_ show: Bool) {
        showInFullscreen = show
        panel?.setShowInFullscreen(show)
        collapsedHoverPanel?.setShowInFullscreen(show)
    }

    /// Applies the selected appearance to the live panel and remembers it for
    /// a panel rebuilt after a screen change. Nil means Follow System.
    func setAppearance(_ appearance: FluxAppearance) {
        appearanceMode = appearance
        panel?.appearance = appearance.nsAppearance
        hostingView?.appearance = appearance.nsAppearance
        refreshRootView()
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
            physicalNotchRect = .null
            removePointerMonitors()
            removeCollapsedClickMonitors()
            collapsedHoverPanel?.orderOut(nil)
            panel?.orderOut(nil)
            viewModel.forceCollapse()
            return
        }

        physicalNotchRect = notchRect
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: screen, notchRect: notchRect)
        hostingView?.rootView = makeRootView(notchRect: notchRect, panelFrame: panel.frame)
        panel.orderFrontRegardless()
        isPresenting = true
        // A state-machine *change* re-syncs `ignoresMouseEvents`/monitors on
        // its own via the `viewModel.$state` sink installed in `init`, but
        // `isPresenting` flipping true here isn't itself a state change (the
        // state could easily already be `.collapsed` from before the screen
        // was lost), so this explicit call is what actually arms the
        // monitors for a freshly-(re)presented panel.
        updatePassThrough(for: viewModel.state)
        // If Flux starts while the pointer is already over the housing, no
        // mouse-enter event is guaranteed. Probe once after attaching so the
        // normal hover delay still starts without requiring a second move.
        if case .collapsed = viewModel.state {
            refreshHover()
        }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(viewModel: viewModel)
        panel.appearance = appearanceMode.nsAppearance
        panel.setShowInFullscreen(showInFullscreen)
        let hosting = NotchHostingView(viewModel: viewModel,
                                       rootView: makeRootView(notchRect: .zero,
                                                              panelFrame: .zero))
        hosting.appearance = appearanceMode.nsAppearance
        panel.contentView = hosting
        hostingView = hosting
        wireDragHandlers(to: panel)
        return panel
    }

    private func makeCollapsedHoverPanel() -> NotchHoverPanel {
        let hoverPanel = NotchHoverPanel(
            onMove: { [weak self] location in
                self?.handleMonitoredMove(at: location)
            },
            onClick: { [weak self] location, modifierFlags in
                self?.handleCollapsedHoverPanelClick(at: location,
                                                     optionDown: modifierFlags.contains(.option))
            })
        hoverPanel.setShowInFullscreen(showInFullscreen)
        collapsedHoverPanel = hoverPanel
        return hoverPanel
    }

    private func makeRootView(notchRect: CGRect, panelFrame: CGRect) -> AnyView {
        let collapsedFrame = NotchMetrics.collapsedFrame(notchRect: notchRect,
                                                         panelFrame: panelFrame)
        return AnyView(NotchRootView(viewModel: viewModel, notchSize: notchRect.size,
                                     collapsedFrame: collapsedFrame.width > 0 ? collapsedFrame : nil,
                                     artworkProvider: artworkProvider,
                                     onActivityTap: onActivityTap))
    }

    private func refreshRootView() {
        guard let hostingView, let panel,
              !physicalNotchRect.isNull else { return }
        hostingView.rootView = makeRootView(notchRect: physicalNotchRect,
                                            panelFrame: panel.frame)
    }

    /// Sizes the panel to the fixed panel bounds (`NotchMetrics.panelBounds`
    /// — wide/tall enough for every widget, and centers it, top-anchored, on the
    /// physical notch. This frame never changes with `viewModel.state` — only
    /// the SwiftUI content inside grows/shrinks, to its own smaller per-widget
    /// size — so repositioning only has to happen when the screen changes.
    private func position(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let bounds = NotchMetrics.panelBounds(for: notchRect.width)
        let origin = NSPoint(x: notchRect.midX - bounds.width / 2, y: screen.frame.maxY - bounds.height)
        panel.setFrame(NSRect(origin: origin, size: bounds), display: true)
    }

    // MARK: - Pass-through, hover, click and context menu

    /// The single place `panel.ignoresMouseEvents` is decided, plus the
    /// monitors that stand in for hit-testing. See `NotchPanel`'s doc comment
    /// for why `hitTest` returning `nil` can't do the pass-through on its own,
    /// and the `globalMoveMonitor` block above for why the move/right-click
    /// monitors are NOT scoped to `.collapsed` the way the left-click pair is.
    ///
    /// Note this intentionally does *not* cover the two-finger swipe gesture
    /// `NotchPanel.sendEvent` recognizes (`swiped(.down)` opening from
    /// `.collapsed`) — `ignoresMouseEvents` suppresses scroll-wheel delivery
    /// to the panel exactly like every other mouse event, so that gesture is
    /// only live while the pointer is inside an open shape. Hover and click
    /// already cover opening from collapsed, so this is a narrower gesture
    /// surface, not a silent break of the primary open paths.
    private func updatePassThrough(for state: NotchState) {
        guard let panel, isPresenting else {
            removePointerMonitors()
            removeCollapsedClickMonitors()
            collapsedHoverPanel?.orderOut(nil)
            return
        }
        installPointerMonitors()
        let wasIgnoring = panel.ignoresMouseEvents
        panel.ignoresMouseEvents = Self.shouldIgnoreMouseEvents(
            state: state,
            pointInsideVisibleShape: pointerInsideVisibleShape(for: state,
                                                                at: NSEvent.mouseLocation))
        switch state {
        case .collapsed:
            installCollapsedClickMonitors()
        case .activity, .expanded:
            removeCollapsedClickMonitors()
        }
        syncCollapsedHoverPanel(for: state)
        // A gesture in flight when this flips is cut off without its `ended`
        // — see `NotchPanel.resetGestureState`.
        if wasIgnoring != panel.ignoresMouseEvents { panel.resetGestureState() }
    }

    /// Shows the exact physical-notch trigger only while the main panel is
    /// collapsed. Keeping this window to the housing itself is what preserves
    /// pass-through for app content below the menu bar, while still giving
    /// AppKit a local mouse target for the collapsed hover path.
    private func syncCollapsedHoverPanel(for state: NotchState) {
        guard Self.shouldShowCollapsedHoverPanel(state: state,
                                                 isPresenting: isPresenting),
              !physicalNotchRect.isNull else {
            collapsedHoverPanel?.orderOut(nil)
            return
        }

        let hoverPanel = collapsedHoverPanel ?? makeCollapsedHoverPanel()
        let rect = Self.collapsedHoverPanelRect(notchRect: physicalNotchRect)
        guard !rect.isNull else {
            hoverPanel.orderOut(nil)
            return
        }
        hoverPanel.setFrame(rect, display: true)
        hoverPanel.orderFrontRegardless()
    }

    /// No-op if already installed — callers (the `viewModel.$state` sink,
    /// `resolveScreen`) can call this freely without risking doubled monitors.
    ///
    /// The guard is an explicit flag, NOT `globalMoveMonitor == nil`.
    /// `NSEvent.addGlobalMonitorForEvents` is documented to return `nil` on
    /// failure, and since M12 this is called on *every* state transition
    /// rather than only when collapsing — so keying idempotence on a token
    /// that can legitimately be nil would re-add the other three monitors on
    /// every collapse/expand: an unbounded monitor leak, N-fold duplicate
    /// hover handling, and N stacked context menus per right-click.
    private func installPointerMonitors() {
        guard !pointerMonitorsInstalled else { return }
        pointerMonitorsInstalled = true

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
        // events while, e.g., the Settings window has focus, or while the
        // panel itself is hit-testable in the open states.
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMonitoredMove(at: NSEvent.mouseLocation)
            return event
        }
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMonitoredRightClick(at: location) }
        }
        localRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.handleMonitoredRightClick(at: NSEvent.mouseLocation)
            return event
        }
        installHoverPollTimer()
    }

    /// AppKit's global monitor is best-effort. A timer is the reliable
    /// fallback for the two cases it cannot cover: a monitor token being nil
    /// because Input Monitoring is unavailable, and a cursor that was already
    /// stationary when the collapsed trigger appeared. This timer observes
    /// only the cursor position; it never owns a window or consumes an event,
    /// so app controls below the notch remain untouched.
    private func installHoverPollTimer() {
        guard hoverPollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.hoverPollInterval, repeats: true) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMonitoredMove(at: location) }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    private func removePointerMonitors() {
        // Deferred for the same reason as `removeCollapsedClickMonitors()` —
        // these local monitors also call their handlers synchronously.
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        let monitors = [globalMoveMonitor, localMoveMonitor,
                        globalRightClickMonitor, localRightClickMonitor].compactMap { $0 }
        if !monitors.isEmpty {
            DispatchQueue.main.async { monitors.forEach { NSEvent.removeMonitor($0) } }
        }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        globalRightClickMonitor = nil
        localRightClickMonitor = nil
        pointerMonitorsInstalled = false

        // `resetHoverState`, NOT `resyncHover`: this is teardown, so the
        // view model's hover intent has to be forgotten without reporting a
        // hover-out — see that method's doc comment. Reporting one schedules
        // a close task that outlives the panel by 0.4s and can land the state
        // machine on `.activity` with nothing to show it in.
        viewModel.resetHoverState()
    }

    private func installCollapsedClickMonitors() {
        // Explicit flag, not `globalClickMonitor == nil` — same reasoning as
        // `installPointerMonitors()`: `addGlobalMonitorForEvents` may return
        // nil, and this runs on every state transition, so a nillable token
        // would re-add the local monitor on each collapse.
        guard !collapsedClickMonitorsInstalled else { return }
        collapsedClickMonitorsInstalled = true
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Captured synchronously alongside the location, for the same
            // reason (see the comment above) — reading `event.modifierFlags`
            // is safe off the main actor since it's a plain stored property
            // on the event, not live global state that could shift under the
            // `Task` hop.
            let location = NSEvent.mouseLocation
            let optionDown = event.modifierFlags.contains(.option)
            Task { @MainActor in self?.handleMonitoredClick(at: location, optionDown: optionDown) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMonitoredClick(at: NSEvent.mouseLocation, optionDown: event.modifierFlags.contains(.option))
            return event
        }
    }

    /// Removal is DEFERRED one runloop turn, and this is load-bearing.
    ///
    /// The local click monitor invokes `handleMonitoredClick` synchronously,
    /// from inside its own block. That calls `viewModel.clicked()` →
    /// `transition` → the `$state` sink → `updatePassThrough(for: .expanded)`
    /// → here. So the common case — clicking the collapsed notch to open it —
    /// reaches this method with the very monitor being removed still on the
    /// stack. `NSEvent.removeMonitor` deallocates the monitor and its block
    /// while AppKit is still executing it. (The global twin is unaffected: it
    /// hops through `Task { @MainActor }` before touching anything.)
    ///
    /// The tokens are nil'd immediately, so nothing can queue a second
    /// removal of the same monitor before the deferred one runs.
    private func removeCollapsedClickMonitors() {
        let monitors = [globalClickMonitor, localClickMonitor].compactMap { $0 }
        globalClickMonitor = nil
        localClickMonitor = nil
        collapsedClickMonitorsInstalled = false
        guard !monitors.isEmpty else { return }
        DispatchQueue.main.async { monitors.forEach { NSEvent.removeMonitor($0) } }
    }

    // MARK: - Geometry

    /// Converts a global screen point into the same space
    /// `NotchViewModel.interactiveRect` is published in: origin at the
    /// panel's TOP-left, y growing downward.
    ///
    /// Derived from the panel's own frame rather than
    /// `NSView.convert(_:from:)`, deliberately. `interactiveRect` is written
    /// by `NotchRootView` in SwiftUI's top-left-origin coordinate space,
    /// whereas an `NSView`'s space is bottom-left-origin unless the view
    /// reports `isFlipped`. Flipping explicitly against `panel.frame.maxY`
    /// makes this correct without depending on `NSHostingView`'s
    /// flippedness, which is an implementation detail of SwiftUI's AppKit
    /// bridge rather than anything documented.
    private func notchSpacePoint(_ screenPoint: NSPoint) -> NSPoint? {
        guard let panel else { return nil }
        let frame = panel.frame
        return NSPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    /// Same conversion, from a WINDOW-space point (what AppKit's dragging
    /// destination callbacks hand over) — window space shares the panel's
    /// origin but is bottom-left, so only the y axis needs flipping.
    private func notchSpacePoint(fromWindow windowPoint: NSPoint) -> NSPoint? {
        guard let panel else { return nil }
        return NSPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
    }

    // Collapsed-state targets are derived from the PHYSICAL notch, in screen
    // coordinates — deliberately not from `viewModel.interactiveRect`.
    //
    // `interactiveRect` is not the collapsed footprint during a transition:
    // `NotchRootView.updateInteractiveRect` widens it to the UNION of the
    // outgoing and incoming shapes for the ~0.35s a collapse spring takes to
    // settle (correct for its own purpose — it keeps the still-visible
    // shrinking shape hit-testable). Deriving collapsed targets from it meant
    // that, for a third of a second after every close, a click or hover
    // anywhere in the *former expanded panel* — well below the menu bar,
    // over another app's window — counted as being on the notch. That both
    // reached the app underneath and re-toggled Flux, which is exactly the
    // horizontal-slop-only invariant the click target is supposed to hold.
    // The physical notch never moves, so it has no such window.

    /// Screen-space hover target for the collapsed notch. Screen coordinates
    /// put y growing UP, so extending "below" the notch means lowering
    /// `minY` — see `hoverSlopBelow` for why that direction gets slop at all.
    ///
    /// Pure and `static`, the same seam `shouldAcceptDrag` uses, so
    /// `--selftest` can drive the geometry headlessly with no window, screen
    /// or physical notch.
    static func collapsedHoverRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return CGRect(x: rect.minX - hoverSlopX,
                      y: rect.minY - hoverSlopBelow,
                      width: rect.width + hoverSlopX * 2,
                      height: rect.height + hoverSlopBelow)
    }

    /// Screen-space click target for the collapsed notch. Horizontal slop
    /// only — unlike hover, a click that lands *below* the menu-bar strip is
    /// a click the user aimed at the window underneath, and toggling the
    /// notch for it would be a genuine misfire rather than a helpful assist.
    static func collapsedClickRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return CGRect(x: rect.minX - clickSlopX, y: rect.minY,
                      width: rect.width + clickSlopX * 2, height: rect.height)
    }

    /// Screen-space frame for the collapsed hover trigger. It deliberately
    /// has no slop. The surrounding forgiving hover band stays monitor-only,
    /// so this companion window cannot block an app toolbar beneath it.
    static func collapsedHoverPanelRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return rect
    }

    /// Whether the exact companion window is the owner of a collapsed click
    /// at `point`. The local click monitor still observes events delivered to
    /// that window, so it must stand down there or the direct view callback
    /// would toggle the state twice. Side-band clicks stay monitor-owned, and
    /// a hidden companion falls back to the monitor path entirely.
    static func collapsedHoverPanelOwnsClick(notchRect rect: CGRect,
                                             point: CGPoint,
                                             isVisible: Bool) -> Bool {
        guard isVisible else { return false }
        return collapsedHoverPanelRect(notchRect: rect).contains(point)
    }

    /// The exact states in which the local collapsed hover trigger is visible.
    /// It must disappear as soon as the real panel opens or loses its screen.
    static func shouldShowCollapsedHoverPanel(state: NotchState,
                                               isPresenting: Bool) -> Bool {
        guard isPresenting else { return false }
        if case .collapsed = state { return true }
        return false
    }

    /// Panel-space hover target for the open shape. The transition union is
    /// wanted here (unlike the collapsed case above): while the shape is
    /// mid-morph the union is a superset of what's actually drawn, which is
    /// what keeps a cursor resting on the still-animating panel from being
    /// read as having left it.
    static func openHoverRect(interactiveRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return rect.insetBy(dx: -openHoverSlop, dy: -openHoverSlop)
    }

    /// Whether the fixed panel should be mouse-transparent for a state and
    /// pointer location. Open states only capture events inside the exact
    /// visible shape; the surrounding panel envelope must stay pass-through
    /// so an app's toolbar below the notch keeps receiving clicks.
    ///
    /// Pure and self-test-covered. Keeping this policy separate from AppKit
    /// lets the low-battery regression run without a window server.
    static func shouldIgnoreMouseEvents(state: NotchState,
                                        pointInsideVisibleShape: Bool) -> Bool {
        switch state {
        case .collapsed:
            return true
        case .activity, .expanded:
            return !pointInsideVisibleShape
        }
    }

    /// The physical notch's own footprint in screen coordinates, or `.null`
    /// when there is no notched screen to speak of.
    ///
    /// Cached from `resolveScreen()` rather than re-derived per event. Two
    /// reasons: `NSScreen.builtInNotchedScreen` scans every screen calling
    /// `CGDisplayIsBuiltin`, and this is now read on every single
    /// `mouseMoved` delivery; and, more importantly, `notchRect`'s own guard
    /// chain depends on `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` being
    /// resolvable at that instant — a transient nil would silently kill
    /// collapsed hover AND click with no recovery, since the screen is only
    /// re-resolved on `didChangeScreenParametersNotification`. The cache is
    /// written at exactly the moment that notification is handled.
    private var physicalNotchRect: CGRect = .null

    /// Whether a screen-space point counts as hovering, for the current
    /// state. Collapsed tests the physical notch directly; the open states
    /// convert into the panel's own space and test the drawn shape.
    private func isHovering(screenPoint: NSPoint) -> Bool {
        switch viewModel.state {
        case .collapsed:
            return Self.collapsedHoverRect(notchRect: physicalNotchRect).contains(screenPoint)
        case .activity, .expanded:
            guard let local = notchSpacePoint(screenPoint) else { return false }
            return Self.openHoverRect(interactiveRect: viewModel.interactiveRect).contains(local)
        }
    }

    /// Exact (no hover slop) containment used only for deciding whether the
    /// fixed panel may capture a click. Hover remains slightly forgiving, but
    /// that extra band must never become a mouse-blocking band over another
    /// app's window.
    private func pointerInsideVisibleShape(for state: NotchState, at screenPoint: NSPoint) -> Bool {
        switch state {
        case .collapsed:
            return false
        case .activity, .expanded:
            guard let local = notchSpacePoint(screenPoint) else { return false }
            return viewModel.interactiveRect.contains(local)
        }
    }

    /// Synchronizes the fixed panel's capture state with the current pointer
    /// location. Called on state/geometry changes and before hover handling so
    /// a panel that is open for a live activity never owns transparent space.
    private func updateMouseCapture(at location: NSPoint) {
        guard let panel, isPresenting else { return }
        let shouldIgnore = Self.shouldIgnoreMouseEvents(
            state: viewModel.state,
            pointInsideVisibleShape: pointerInsideVisibleShape(for: viewModel.state,
                                                                at: location))
        guard panel.ignoresMouseEvents != shouldIgnore else { return }
        panel.ignoresMouseEvents = shouldIgnore
        panel.resetGestureState()
    }

    /// Where a right-click pops the context menu: the physical notch's own
    /// strip, in EVERY state.
    ///
    /// Not the whole open shape, which is what this first did. Two separate
    /// problems with that:
    /// - The expanded Shelf and Clipboard widgets attach their own SwiftUI
    ///   `.contextMenu` to their tiles/rows (AirDrop, Show in Finder, Copy,
    ///   Remove). A local monitor observes the right-click without consuming
    ///   it, so the same event would open the widget's menu *and* schedule
    ///   this shell menu — two menus fighting over one click, with the shell
    ///   one reopening after the intended one was dismissed.
    /// - A global monitor can't consume the event either, so while collapsed
    ///   a right-click reaching past the menu-bar strip would pop this menu
    ///   on top of whatever context menu the window underneath shows.
    ///
    /// The physical notch is the one region that is always Flux's own chrome
    /// and never a widget's content — expanded content clears it by
    /// `notchSize.height + 6` of top padding (see `NotchRootView.
    /// ExpandedChrome`) — so confining the shell menu to it resolves both.
    private var contextMenuRect: CGRect {
        Self.collapsedClickRect(notchRect: physicalNotchRect)
    }

    // MARK: - Monitored input

    private func handleMonitoredMove(at location: NSPoint) {
        guard isPresenting, !isShowingMenu else { return }
        updateMouseCapture(at: location)
        let inside = isHovering(screenPoint: location)
        // Forward every sampled result. A controller-side cache can be stale
        // after a monitor is reinstalled or a tracking window is ordered out
        // while the cursor stays still. The view model owns the authoritative
        // change-debounce, so it can recover immediately instead of waiting
        // for the next edge.
        viewModel.hoverChanged(inside: inside)
    }

    /// Re-derives hover from wherever the cursor actually is right now,
    /// Used after the context menu closes: every move made while it was
    /// tracking was suppressed, so the view model's cached value is
    /// meaningless — and a normal debounced report could swallow the one
    /// that matters (cursor now outside), leaving the panel pinned open.
    private func refreshHover() {
        guard isPresenting else { return }
        let location = NSEvent.mouseLocation
        updateMouseCapture(at: location)
        let inside = isHovering(screenPoint: location)
        // `resyncHover`, not `hoverChanged`: the view model's own
        // `isHovering` cache is stale by construction here — see that
        // method's doc comment.
        viewModel.resyncHover(inside: inside)
    }

    /// A click landing on the notch while collapsed would otherwise be lost
    /// entirely — `ignoresMouseEvents` means `NotchRootView`'s own
    /// `onTapGesture` never sees it. Global monitors can't consume/swallow
    /// the event they observe, which is fine here: the physical notch has no
    /// real pixels for another app to receive that same click instead.
    ///
    /// `optionDown` is forwarded straight to `NotchViewModel.clicked(optionDown:)`
    /// so an option-click restores the last-dismissed live activity even
    /// while collapsed, matching `NotchRootView.handleTap`'s own option-click
    /// handling for the activity/expanded states (where the panel itself
    /// receives the click instead of these monitors).
    private func handleMonitoredClick(at location: NSPoint, optionDown: Bool) {
        guard isPresenting, !isShowingMenu,
              case .collapsed = viewModel.state,
              Self.collapsedClickRect(notchRect: physicalNotchRect).contains(location) else { return }
        // When the exact companion is visible it receives the event itself
        // and invokes the direct path below. The local monitor still sees the
        // same event, so leave it alone to avoid a double toggle. If the
        // companion is hidden, this monitor remains the fallback owner.
        guard !Self.collapsedHoverPanelOwnsClick(
            notchRect: physicalNotchRect,
            point: location,
            isVisible: collapsedHoverPanel?.isVisible == true) else { return }
        viewModel.clicked(optionDown: optionDown)
    }

    /// Direct click path for the exact collapsed trigger window. AppKit can
    /// deliver this local `mouseDown` even when Flux is not the active app;
    /// handling it at the view boundary removes the timing gap where a local
    /// monitor could miss the event. The monitor path still covers the
    /// forgiving horizontal side band outside this window.
    private func handleCollapsedHoverPanelClick(at location: NSPoint,
                                                optionDown: Bool) {
        guard isPresenting, !isShowingMenu,
              case .collapsed = viewModel.state,
              Self.collapsedHoverPanelOwnsClick(
                  notchRect: physicalNotchRect,
                  point: location,
                  // This callback can only come from the visible trigger
                  // view itself; do not depend on AppKit's `isVisible` bit,
                  // which can lag by one event during an order-front.
                  isVisible: true) else { return }
        viewModel.clicked(optionDown: optionDown)
    }

    /// Right-click anywhere on the physical notch — in any state — pops up
    /// the app's context menu, matching the chevron's own right-click
    /// affordance in the menu bar. It uses the safe horizontal click band,
    /// not the broader hover-only band, so a right-click below the menu bar
    /// can never summon Flux over another app.
    ///
    /// Popped on the next runloop turn rather than inline: `NSMenu.popUp`
    /// spins its own modal tracking loop, and starting that from inside an
    /// event monitor's callback (i.e. partway through AppKit's own delivery
    /// of the very click being handled) is asking for re-entrancy trouble.
    /// `isShowingMenu` suppresses hover for the menu's lifetime — see that
    /// property's doc comment.
    private func handleMonitoredRightClick(at location: NSPoint) {
        guard isPresenting, !isShowingMenu,
              contextMenuRect.contains(location),
              let menu = menuProvider?() else { return }

        // Set SYNCHRONOUSLY, not inside the block below: two right-clicks
        // landing before the first block runs would both pass the guard
        // above and queue two `popUp` calls, so the menu would reopen by
        // itself the moment the user dismissed it.
        isShowingMenu = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `in: nil` makes `location` a screen coordinate, which is what
            // the monitors already hand us.
            menu.popUp(positioning: nil, at: location, in: nil)
            self.isShowingMenu = false
            // The pointer is wherever the menu left it, and every move made
            // while the menu was up was suppressed — so re-derive hover from
            // the live cursor position instead of trusting the pre-menu one.
            self.refreshHover()
        }
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
        guard let localPoint = notchSpacePoint(fromWindow: windowLocation) else { return [] }
        return handleDraggingUpdate(localPoint: localPoint)
    }

    private func handleDraggingUpdate(localPoint: NSPoint) -> NSDragOperation {
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

        let result = onShelfDrop?(urls) ?? .declined
        guard result.accepted > 0 else { return false }

        // Present tense while anything is still copying — see
        // `ShelfDropResult`. The shelf itself is the honest, live answer:
        // items appear in it as their copies finish, and one that fails
        // simply never shows up.
        let stillCopying = result.accepted - result.ready
        let caption = stillCopying > 0 ? "Adding \(result.accepted)…" : "Added \(result.ready)"

        activities.post(LiveActivity(
            kind: .shelfDrop,
            leading: .icon(systemName: "tray.and.arrow.down.fill"),
            trailing: .text(caption),
            duration: 2.5,
            priority: 120))
        return true
    }
}
