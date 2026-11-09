import AppKit
import FluxCore
import FluxUI

/// Owns the one notch window: a borderless, nonactivating `NSPanel` that shows
/// `CompactNotchController` (closed) or `NotchPanelController` (open).
///
/// The parent owns `FeatureDemand`, `FeatureRuntime`, the activity queue,
/// every service and the global shortcut. This type owns only the window, its
/// two content controllers, hover tracking and one close-delay task.
///
/// Order it keeps:
/// 1. Before a widget becomes visible: `willShowWidget(from, to)`, then
///    `makeWidget(to)`. Only the selected widget is made.
/// 2. Before a widget view goes: `willDismissWidget(widget)`. The parent
///    applies `FeatureDemand` with no visible widget and stops the camera
///    there, then calls `WidgetCoordinator.dismiss()`. The view is removed after.
///
/// There is no idle timer and no event monitor. Hover uses an `NSTrackingArea`
/// on the window content. A close delay is one `Task.sleep`, cancelled on
/// re-entry, collapse, lock, disable and stop.
///
/// File drags: the window is an AppKit drag destination for file URLs only.
/// A file drag over the compact notch opens File Shelf without focus. If it
/// leaves the window with no drop, only the panel that this drag opened
/// closes. An open panel that shows another widget is never switched. The
/// shelf root and the window never take the same drop: AppKit gives each
/// drop to one destination, and both send it to the same shelf copy job.
@MainActor
public final class NotchWindowCoordinator {
    public enum Presentation: Equatable, Sendable {
        /// Not started, stopped, or the session is locked. No window is on screen.
        case hidden
        case compact
        case expanded(Widget)
    }

    public struct Callbacks {
        public var willShowWidget: @MainActor (_ from: Widget?, _ to: Widget) -> Void
        public var makeWidget: @MainActor (Widget) -> NSViewController
        public var willDismissWidget: @MainActor (Widget?) -> Void
        /// `.cycle`, `.dismissActivity` and `.restoreActivity`. `.expand` is
        /// handled here and is not forwarded.
        public var compactAction: @MainActor (CompactNotchAction) -> Void
        /// Duo calendar pane: `.calendar` before `makeWidget(.calendar)` for
        /// the pane, nil after the pane is removed. `willDismissWidget` still
        /// runs once for the whole panel, before both views go.
        public var companionChanged: @MainActor (Widget?) -> Void
        /// True when the open File Shelf can take a drop now. Asked on each
        /// drag move over the open panel outside the shelf root.
        public var shelfDropReady: @MainActor () -> Bool
        /// A drop on the open panel outside the shelf root. Return true only
        /// if the shelf copy job took the files. Called once per drop.
        public var shelfDrop: @MainActor ([URL]) -> Bool

        public init(willShowWidget: @escaping @MainActor (_ from: Widget?, _ to: Widget) -> Void,
                    makeWidget: @escaping @MainActor (Widget) -> NSViewController,
                    willDismissWidget: @escaping @MainActor (Widget?) -> Void,
                    compactAction: @escaping @MainActor (CompactNotchAction) -> Void,
                    companionChanged: @escaping @MainActor (Widget?) -> Void = { _ in },
                    shelfDropReady: @escaping @MainActor () -> Bool = { false },
                    shelfDrop: @escaping @MainActor ([URL]) -> Bool = { _ in false }) {
            self.willShowWidget = willShowWidget
            self.makeWidget = makeWidget
            self.willDismissWidget = willDismissWidget
            self.compactAction = compactAction
            self.companionChanged = companionChanged
            self.shelfDropReady = shelfDropReady
            self.shelfDrop = shelfDrop
        }
    }

    /// The expanded panel never takes more than this share of the screen height.
    public static let maximumHeightFraction: CGFloat = 0.8
    /// Hover close delay limits, in seconds.
    public static let closeDelayRange: ClosedRange<TimeInterval> = 0...10

    public private(set) var presentation: Presentation = .hidden {
        didSet { if oldValue != presentation { onPresentationChange?(presentation) } }
    }
    public var onPresentationChange: (@MainActor (Presentation) -> Void)?
    public private(set) var geometry: NotchGeometry?
    public private(set) var widgets: [Widget] = []
    public private(set) var isLocked = false
    /// The parent's last `setDuo(_:)` value. Kept across collapse and reopen.
    public private(set) var isDuoRequested = false
    /// The Duo calendar pane, while one is shown.
    public var companion: Widget? { panel?.companion }
    /// The parent's last `setShowInFullscreen(_:)` value. Default true.
    public private(set) var showsInFullscreen = true
    /// The `draggingSequenceNumber` of the file drag that opened File Shelf
    /// from the compact notch. Nil when no open drag owns the panel.
    public private(set) var dragOpenedSession: Int?

    private let callbacks: Callbacks
    private var window: NotchWindow?
    private var compact: CompactNotchController?
    private var panel: NotchPanelController?
    private var panelWidth: NSLayoutConstraint?
    private var compactState: (activity: ActivityItem?, artwork: NSImage?, count: Int, restorable: Int) = (nil, nil, 0, 0)
    private var lastWidget: Widget?
    private var started = false
    private var collapsing = false
    private var openedWithFocus = false

    private var hoverEnabled = false
    private var closeDelay: TimeInterval = 0.5
    private let tracker = NotchHoverTracker()
    private var trackingArea: NSTrackingArea?
    private weak var trackedView: NSView?
    private var closeTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var refitTask: Task<Void, Never>?

    public init(callbacks: Callbacks) {
        self.callbacks = callbacks
        tracker.onEnter = { [weak self] in self?.pointerEntered() }
        tracker.onExit = { [weak self] in self?.pointerExited() }
    }

    // MARK: Geometry

    /// Geometry for `screen` from its current notch areas. A display without
    /// a notch gets `cameraWidth` 0 and the menu bar height as `topInset`.
    public static func geometry(for screen: NSScreen) -> NotchGeometry {
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        guard let left, let right, !left.isEmpty, !right.isEmpty else {
            return NotchGeometry(screenFrame: screen.frame, cameraWidth: 0, topInset: menuBar)
        }
        // The areas may be screen-relative or global. Their gap is the same.
        let inset = max(left.height, right.height, screen.safeAreaInsets.top)
        return NotchGeometry(screenFrame: screen.frame, cameraWidth: max(0, right.minX - left.maxX), topInset: inset)
    }

    // MARK: Lifecycle

    /// Shows the compact notch on `screen`. Calling it again moves to a new screen.
    public func start(screen: NSScreen, widgets: [Widget]) {
        started = true
        setWidgets(widgets)
        update(screen: screen)
        if !isLocked, presentation == .hidden { showCompact() }
    }

    /// Dismisses any widget through `willDismissWidget`, closes the window and
    /// releases both controllers. Hover and the close task stop.
    public func stop() {
        started = false
        tearDown()
        geometry = nil
    }

    /// New display or changed notch areas. An open panel collapses first, so
    /// the old widget and camera go before the window moves.
    public func update(screen: NSScreen) {
        let next = Self.geometry(for: screen)
        guard next != geometry else { return }
        if case .expanded = presentation { collapse() }
        geometry = next
        if presentation == .compact { renderCompact() }
    }

    /// The parent's lock and unlock events. Locking hides the window and stops hover work.
    public func setSessionLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked { tearDown() } else if started { showCompact() }
    }

    /// Enabled widgets in saved order. An open panel updates its tabs. If the
    /// shown widget goes, the panel shows the first one left, or collapses.
    public func setWidgets(_ newWidgets: [Widget]) {
        widgets = Self.unique(newWidgets)
        if let lastWidget, !widgets.contains(lastWidget) { self.lastWidget = nil }
        if !widgets.contains(.shelf) { dragOpenedSession = nil }
        panel?.setWidgets(widgets)
    }

    /// The current activity from `ActivityQueue`. Parent data only.
    public func updateActivity(_ activity: ActivityItem?, artwork: NSImage?, queueCount: Int, restorableCount: Int) {
        compactState = (activity, artwork, queueCount, restorableCount)
        if presentation == .compact { renderCompact() }
    }

    /// Duo view on or off. The parent sends true only when the saved Duo
    /// switch is on, Calendar access is allowed, the Calendar widget is
    /// enabled and the agenda has a relevant event. It shows only while
    /// Now Playing is open. The window refits once on the next turn.
    public func setDuo(_ requested: Bool) {
        guard requested != isDuoRequested else { return }
        isDuoRequested = requested
        panel?.setDuo(requested)
    }

    /// Late content: call after you send a widget new state that can change
    /// its height, for example Calendar `.loading` to `.events`, Now Playing
    /// `.loading` to `.playing`, or a File Shelf item list. It does nothing
    /// unless `widget` is shown, as the open tab or the Duo pane. Calls in
    /// one main-actor turn give one refit on the next turn. No timer, no poll.
    public func contentDidChange(_ widget: Widget) {
        guard case .expanded(let open) = presentation, panel != nil,
              open == widget || companion == widget else { return }
        scheduleRefit()
    }

    /// Saved `Preferences.showInFullscreen`. True keeps `.fullScreenAuxiliary`,
    /// so the notch shows over full-screen apps. False removes it, as the
    /// old app did. AppKit then keeps the window out of full-screen Spaces,
    /// and opens, hover and drags are refused while the window is not on the
    /// active Space. An open panel collapses when the option turns off.
    public func setShowInFullscreen(_ show: Bool) {
        guard show != showsInFullscreen else { return }
        showsInFullscreen = show
        window?.setShowInFullscreen(show)
        if !show { collapse() }
    }

    /// Hover open and close. `closeDelay` is clamped to `closeDelayRange`.
    public func setHover(enabled: Bool, closeDelay: TimeInterval) {
        self.closeDelay = closeDelay.isFinite
            ? min(max(closeDelay, Self.closeDelayRange.lowerBound), Self.closeDelayRange.upperBound) : 0.5
        guard enabled != hoverEnabled else { return }
        hoverEnabled = enabled
        if enabled { trackContent() } else { untrack() }
    }

    // MARK: Open and close

    /// Opens a widget. `focus: true` is for a keyboard shortcut or a menu
    /// command only: the window becomes key without activating the app.
    /// Background and hover opens never take focus.
    public func expand(_ widget: Widget? = nil, focus: Bool) {
        guard started, !isLocked, let geometry, let window, isOnShownSpace else { return }
        guard let target = widget.flatMap({ widgets.contains($0) ? $0 : nil })
                ?? lastWidget.flatMap({ widgets.contains($0) ? $0 : nil }) ?? widgets.first else { return }
        cancelClose()
        openedWithFocus = openedWithFocus || focus
        if let panel, case .expanded = presentation {
            panel.show(target)
        } else {
            let controller = NotchPanelController(widgets: widgets, geometry: geometry) { [weak self] widget in
                guard let self else { return NSViewController() }
                let content = self.callbacks.makeWidget(widget)
                (content as? FileShelfWidgetController)?.onDragSession = { [weak self, weak content] event in
                    guard let self, let content, self.started, !self.isLocked,
                          let window = self.window, self.panel?.current == .shelf,
                          content.isViewLoaded, content.view.window === window else { return }
                    self.shelfDragEvent(event)
                }
                return content
            }
            controller.onWillSwitch = { [weak self] from, to in self?.panelWillSwitch(from: from, to: to) }
            controller.onWillDismiss = { [weak self] widget in self?.panelWillDismiss(widget) }
            controller.onCompanionChange = { [weak self] widget in self?.callbacks.companionChanged(widget) }
            controller.onLayoutChange = { [weak self] in self?.scheduleRefit() }
            controller.setDuo(isDuoRequested)
            panel = controller
            let width = controller.view.widthAnchor.constraint(equalToConstant: geometry.expandedRect(contentHeight: 0).width)
            width.isActive = true
            panelWidth = width
            presentation = .expanded(target)
            // Show the target before the view enters the window. Otherwise
            // `viewDidAppear` would make the first widget, then switch.
            controller.show(target)
            window.contentViewController = controller
            trackContent()
        }
        presentation = .expanded(target)
        resizeExpanded()
        if focus { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
    }

    /// Keyboard shortcut toggle. Opens with focus, or collapses.
    public func toggle() {
        if case .expanded = presentation { collapse() } else { expand(focus: true) }
    }

    /// Back to the compact notch. The widget is dismissed before its view goes.
    public func collapse() {
        cancelClose()
        guard case .expanded = presentation else { return }
        dismissPanel()
        showCompact()
    }

    // MARK: Private

    private func showCompact() {
        guard started, !isLocked, geometry != nil else { return }
        let window = self.window ?? makeWindow()
        presentation = .compact
        openedWithFocus = false
        dragOpenedSession = nil
        renderCompact()
        if window.contentViewController !== compact { window.contentViewController = compact }
        trackContent()
        layoutCompact()
        window.orderFrontRegardless()
    }

    private func renderCompact() {
        guard let geometry else { return }
        let state = CompactNotchState(geometry: geometry, currentActivity: compactState.activity, artwork: compactState.artwork,
                                      queueCount: compactState.count, restorableCount: compactState.restorable)
        if let compact {
            compact.update(state)
        } else {
            compact = CompactNotchController(state: state) { [weak self] in self?.compactAction($0) }
        }
        if presentation == .compact, window?.contentViewController === compact { layoutCompact() }
    }

    private func layoutCompact() {
        guard let geometry, let compact, let window else { return }
        let size = compact.preferredSize
        let frame = NSRect(x: geometry.screenFrame.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func resizeExpanded() {
        guard let geometry, let panel, let window else { return }
        let width = geometry.expandedRect(contentHeight: 0).width
        let limit = max(geometry.topInset, geometry.screenFrame.height * Self.maximumHeightFraction)
        panelWidth?.constant = width
        // The panel scrolls widget content past this cap, so its required
        // constraints never ask AppKit for a taller window than `limit`.
        panel.maximumHeight = limit
        panel.view.layoutSubtreeIfNeeded()
        let fitting = panel.view.fittingSize.height
        let content = min(max(fitting.isFinite ? fitting : 0, geometry.topInset), limit) - geometry.topInset
        let frame = geometry.expandedRect(contentHeight: content)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func compactAction(_ action: CompactNotchAction) {
        switch action {
        case .expand:
            let keyboard = NSApp.currentEvent.map { $0.type == .keyDown } ?? false
            expand(focus: keyboard)
        case .cycle, .dismissActivity, .restoreActivity:
            callbacks.compactAction(action)
        }
    }

    private func panelWillSwitch(from: Widget?, to: Widget) {
        callbacks.willShowWidget(from, to)
        if to != .shelf { dragOpenedSession = nil }
        lastWidget = to
        presentation = .expanded(to)
        // A tab click switches after this returns. Fit once, on the next turn.
        scheduleRefit()
    }

    private func panelWillDismiss(_ widget: Widget?) {
        callbacks.willDismissWidget(widget)
        guard !collapsing else { return }
        // Escape or an empty widget list closed the panel from inside.
        schedule { coordinator in
            guard case .expanded = coordinator.presentation else { return }
            coordinator.releasePanel()
            coordinator.showCompact()
        }
    }

    /// Dismisses the widget through the panel, then drops the panel.
    private func dismissPanel() {
        guard let panel else { return }
        collapsing = true
        panel.dismiss()
        collapsing = false
        releasePanel()
    }

    private func releasePanel() {
        pendingTask?.cancel(); pendingTask = nil
        refitTask?.cancel(); refitTask = nil
        panelWidth = nil
        if let window, window.contentViewController === panel { window.contentViewController = nil }
        panel = nil
        if case .expanded = presentation { presentation = .hidden }
    }

    private func tearDown() {
        cancelClose()
        untrack()
        if case .expanded = presentation { dismissPanel() }
        pendingTask?.cancel(); pendingTask = nil
        refitTask?.cancel(); refitTask = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
        compact = nil
        presentation = .hidden
        openedWithFocus = false
        dragOpenedSession = nil
    }

    private func makeWindow() -> NotchWindow {
        let window = NotchWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.applyNotchStyle()
        window.setShowInFullscreen(showsInFullscreen)
        window.onDragUpdate = { [weak self, weak window] info in
            guard let self, let window, self.window === window else { return [] }
            return self.dragUpdated(info, in: window)
        }
        window.onDragExit = { [weak self, weak window] info in
            guard let self, let window, self.window === window else { return }
            self.dragExited(session: info?.draggingSequenceNumber, location: info?.draggingLocation)
        }
        window.onDragPerform = { [weak self, weak window] info in
            guard let self, let window, self.window === window else { return false }
            return self.dragPerformed(info, in: window)
        }
        window.onDragEnd = { [weak self, weak window] info in
            guard let self, let window, self.window === window else { return }
            self.dragEnded(session: info.draggingSequenceNumber)
        }
        self.window = window
        return window
    }

    /// False only when fullscreen showing is off and AppKit reports the
    /// window off the active Space. With the option on, AppKit may report a
    /// visible `.fullScreenAuxiliary` window as off the active Space, so the
    /// flag is read only for the opt-out path, as the old app did.
    private var isOnShownSpace: Bool {
        guard let window else { return false }
        return showsInFullscreen || window.isOnActiveSpace
    }

    // MARK: File drag

    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// A user drag of file URLs from outside this window, while the notch is shown.
    private func isEligibleDrag(_ info: any NSDraggingInfo, in window: NotchWindow) -> Bool {
        guard started, !isLocked, isOnShownSpace, widgets.contains(.shelf),
              info.draggingSourceOperationMask.contains(.copy) else { return false }
        if let source = info.draggingSource as? NSView, source.window === window { return false }
        if let source = info.draggingSource as? NSWindow, source === window { return false }
        // Checks the types only. It reads no file and no image.
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly)
    }

    private func dragUpdated(_ info: any NSDraggingInfo, in window: NotchWindow) -> NSDragOperation {
        guard isEligibleDrag(info, in: window) else { return [] }
        switch presentation {
        case .compact:
            dragOpenedSession = info.draggingSequenceNumber
            expand(.shelf, focus: false)
            guard presentation == .expanded(.shelf) else { dragOpenedSession = nil; return [] }
            // The shelf may still be loading. The drop checks it again.
            return .copy
        case .expanded(.shelf):
            return callbacks.shelfDropReady() ? .copy : []
        case .expanded, .hidden:
            return []
        }
    }

    /// A drop on the window outside the shelf root. The shelf stays open.
    private func dragPerformed(_ info: any NSDraggingInfo, in window: NotchWindow) -> Bool {
        guard isEligibleDrag(info, in: window), presentation == .expanded(.shelf), callbacks.shelfDropReady(),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL],
              !urls.isEmpty else { return false }
        let accepted = callbacks.shelfDrop(urls)
        if accepted { dragCompleted(session: info.draggingSequenceNumber) }
        return accepted
    }

    private func shelfDragEvent(_ event: FileShelfDragEvent) {
        switch event {
        case .exited(let session, let location): dragExited(session: session, location: location)
        case .dropped(let session): dragCompleted(session: session)
        case .ended(let session): dragEnded(session: session)
        }
    }

    /// The drag left the window or the shelf root. A point still inside the
    /// window is a move between those two destinations, not an exit.
    private func dragExited(session: Int?, location: NSPoint?) {
        guard let opened = dragOpenedSession, session == nil || session == opened else { return }
        if let location, let window, NSRect(origin: .zero, size: window.frame.size).contains(location) { return }
        dragOpenedSession = nil
        guard presentation == .expanded(.shelf) else { return }
        collapse()
    }

    private func dragCompleted(session: Int) {
        if dragOpenedSession == session { dragOpenedSession = nil }
    }

    /// AppKit ends a canceled drag even when its last location is inside.
    /// A successful drop already released this session's auto-open ownership.
    private func dragEnded(session: Int) {
        guard dragOpenedSession == session else { return }
        dragOpenedSession = nil
        if presentation == .expanded(.shelf) { collapse() }
    }

    /// One pending main-actor turn. A newer request replaces it.
    private func schedule(_ work: @escaping @MainActor (NotchWindowCoordinator) -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            work(self)
        }
    }

    /// One refit on the next main-actor turn. Separate from `schedule`, so a
    /// refit never cancels a pending return to compact. Extra calls before it
    /// runs join it.
    private func scheduleRefit() {
        guard refitTask == nil else { return }
        refitTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.refitTask = nil
            guard case .expanded = self.presentation else { return }
            self.resizeExpanded()
        }
    }

    // MARK: Hover

    private func trackContent() {
        guard hoverEnabled, let view = window?.contentView else { return }
        if trackedView === view, trackingArea != nil { return }
        untrack()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: tracker, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
        trackedView = view
    }

    private func untrack() {
        cancelClose()
        if let trackingArea, let trackedView { trackedView.removeTrackingArea(trackingArea) }
        trackingArea = nil
        trackedView = nil
    }

    private func pointerEntered() {
        guard hoverEnabled, isOnShownSpace else { return }
        cancelClose()
        if presentation == .compact { expand(focus: false) }
    }

    private func pointerExited() {
        guard hoverEnabled, case .expanded = presentation, !openedWithFocus else { return }
        cancelClose()
        let delay = closeDelay
        closeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.closeTask = nil
            self.collapse()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    private static func unique(_ list: [Widget]) -> [Widget] {
        list.reduce(into: []) { result, widget in if !result.contains(widget) { result.append(widget) } }
    }
}

/// Borderless, nonactivating, clear and on every Space. It shows over
/// full-screen apps only while `setShowInFullscreen(true)` holds.
/// It becomes key only when a control needs it or the coordinator asks.
@MainActor
final class NotchWindow: NSPanel {
    var onDragUpdate: (@MainActor (any NSDraggingInfo) -> NSDragOperation)?
    var onDragExit: (@MainActor ((any NSDraggingInfo)?) -> Void)?
    var onDragPerform: (@MainActor (any NSDraggingInfo) -> Bool)?
    var onDragEnd: (@MainActor (any NSDraggingInfo) -> Void)?

    func applyNotchStyle() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        registerForDraggedTypes([.fileURL])
    }

    /// Adds or removes `.fullScreenAuxiliary` only. Spaces flags stay.
    func setShowInFullscreen(_ show: Bool) {
        if show { collectionBehavior.insert(.fullScreenAuxiliary) } else { collectionBehavior.remove(.fullScreenAuxiliary) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// `NSWindow` has the drag destination methods only as an informal
// Objective-C category. The conformance exposes the main-actor witnesses to
// AppKit by selector.
extension NotchWindow: NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { onDragUpdate?(sender) ?? [] }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { onDragUpdate?(sender) ?? [] }
    func draggingExited(_ sender: (any NSDraggingInfo)?) { onDragExit?(sender) }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { onDragPerform?(sender) ?? false }
    func draggingEnded(_ sender: any NSDraggingInfo) { onDragEnd?(sender) }
    // Shelf loading can finish while the pointer stays still. AppKit must
    // refresh the accepted operation during that drag, including [] to copy.
    func wantsPeriodicDraggingUpdates() -> Bool { true }
}

/// Receives tracking-area events. Holds no window or view.
@MainActor
final class NotchHoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init() { super.init() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
