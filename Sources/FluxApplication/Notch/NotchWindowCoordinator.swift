import AppKit
import FluxCore
import FluxUI
// Scoped: SwiftUI also declares `Widget`.
import struct SwiftUI.AnyView
import protocol SwiftUI.NSViewRepresentable

// Ported from Flux 0.21.35: Sources/Flux/Notch/NotchWindowController.swift.
// Screen resolution, pass-through, hover and click slop, the collapsed hover
// trigger, the context menu, swipes and file drags follow the old controller.
// One change keeps idle cost at zero: there is no cursor poll timer. Hover
// comes from the tracking areas and the mouse-moved monitors only, plus one
// probe whenever the panel attaches or changes state.

/// Owns the notch window on the built-in notched display: one fixed,
/// transparent panel that hosts `NotchRootView`, and a tiny trigger window
/// over the physical notch while collapsed.
///
/// Widget order it keeps:
/// 1. Before a widget is shown: `willShowWidget(from, to)`, then `makeWidget(to)`.
/// 2. Before a widget goes: `willDismissWidget(widget)`, then its controller
///    is released. The Duo Calendar pane follows `companionChanged`.
@MainActor
public final class NotchWindowCoordinator {
    public enum Presentation: Equatable, Sendable {
        /// Not started, stopped, locked, or no notched display.
        case hidden
        /// The closed notch, with or without a live activity.
        case compact
        case expanded(Widget)
    }

    public struct Callbacks {
        public var willShowWidget: @MainActor (_ from: Widget?, _ to: Widget) -> Void
        public var makeWidget: @MainActor (Widget) -> NSViewController
        public var willDismissWidget: @MainActor (Widget?) -> Void
        /// `.cycle`, `.dismissActivity` and `.restoreActivity`.
        public var compactAction: @MainActor (CompactNotchAction) -> Void
        /// `.calendar` before `makeWidget(.calendar)` for the Duo pane, nil
        /// after the pane is released.
        public var companionChanged: @MainActor (Widget?) -> Void
        /// A drop on the notch. Return true only if the shelf took the files.
        public var shelfDrop: @MainActor ([URL]) -> Bool
        /// The menu a right-click on the physical notch shows.
        public var contextMenu: @MainActor () -> NSMenu?
        /// A tap on a live activity. Return true to claim it.
        public var activityTap: @MainActor (ActivityKind) -> Bool

        public init(willShowWidget: @escaping @MainActor (_ from: Widget?, _ to: Widget) -> Void,
                    makeWidget: @escaping @MainActor (Widget) -> NSViewController,
                    willDismissWidget: @escaping @MainActor (Widget?) -> Void,
                    compactAction: @escaping @MainActor (CompactNotchAction) -> Void,
                    companionChanged: @escaping @MainActor (Widget?) -> Void = { _ in },
                    shelfDrop: @escaping @MainActor ([URL]) -> Bool = { _ in false },
                    contextMenu: @escaping @MainActor () -> NSMenu? = { nil },
                    activityTap: @escaping @MainActor (ActivityKind) -> Bool = { _ in false }) {
            self.willShowWidget = willShowWidget
            self.makeWidget = makeWidget
            self.willDismissWidget = willDismissWidget
            self.compactAction = compactAction
            self.companionChanged = companionChanged
            self.shelfDrop = shelfDrop
            self.contextMenu = contextMenu
            self.activityTap = activityTap
        }
    }

    /// Hover close delay limits, in seconds.
    public static let closeDelayRange: ClosedRange<TimeInterval> = 0...10

    // Slop values from 0.21.35.
    static let dragSlop: CGFloat = 20
    static let hoverSlopX: CGFloat = 24
    static let clickSlopX: CGFloat = 16
    static let hoverSlopBelow: CGFloat = 20
    static let openHoverSlop: CGFloat = 4
    static let screenRetryDelays: [TimeInterval] = [0.05, 0.20, 0.60, 1.20, 2.50, 5.00]

    public private(set) var presentation: Presentation = .hidden {
        didSet { if oldValue != presentation { onPresentationChange?(presentation) } }
    }
    public var onPresentationChange: (@MainActor (Presentation) -> Void)?
    public let viewModel = NotchViewModel()
    public private(set) var widgets: [Widget] = []
    public private(set) var isLocked = false
    public private(set) var isDuoRequested = false
    public private(set) var showsInFullscreen = true
    /// The Duo Calendar pane, while one is shown.
    public private(set) var companion: Widget?
    /// The physical notch in screen coordinates, while presenting.
    public private(set) var physicalNotchRect: CGRect = .null
    public private(set) var isPresenting = false

    private let callbacks: Callbacks
    private let resolveNotch: @MainActor () -> (screen: NSScreen, notch: CGRect)?
    private var started = false
    private var window: NotchWindow?
    private var hostingView: NotchHostingView?
    private var hoverPanel: NotchHoverPanel?
    private var appearance: NSAppearance? = NSAppearance(named: .darkAqua)
    private var primaryWidget: Widget?
    private var primaryController: NSViewController?
    private var companionController: NSViewController?
    private var observers: [NSObjectProtocol] = []
    private var screenTask: Task<Void, Never>?
    private var resampleTask: Task<Void, Never>?
    private var dragSessionEntered = false
    private var isShowingMenu = false {
        didSet { viewModel.suppressHover = isShowingMenu }
    }

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var localRightClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var pointerMonitorsInstalled = false
    private var collapsedClickMonitorsInstalled = false

    /// `resolveNotch` finds the display and its notch. The default is the
    /// built-in notched display, as in 0.21.35. Tests pass a fixed rect.
    public init(callbacks: Callbacks,
                resolveNotch: (@MainActor () -> (screen: NSScreen, notch: CGRect)?)? = nil) {
        self.callbacks = callbacks
        self.resolveNotch = resolveNotch ?? {
            guard let screen = NSScreen.builtInNotchedScreen, let rect = screen.physicalNotchRect else { return nil }
            return (screen, rect)
        }
        viewModel.onPresent = { [weak self] from, to in self?.present(from: from, to: to) }
        viewModel.onDismiss = { [weak self] widget in self?.dismiss(widget) }
        viewModel.onStateChange = { [weak self] state in self?.stateChanged(state) }
        viewModel.onCycleActivity = { [weak self] in self?.callbacks.compactAction(.cycle) }
        viewModel.onDismissActivity = { [weak self] in self?.callbacks.compactAction(.dismissActivity) }
        viewModel.onRestoreActivity = { [weak self] in self?.callbacks.compactAction(.restoreActivity) }
        viewModel.onActivityTap = { [weak self] kind in self?.callbacks.activityTap(kind) ?? false }
        viewModel.widgetContent = { [weak self] widget in self?.content(for: widget) }
    }

    /// Geometry for `screen` from its notch areas, for the lock screen and
    /// fixtures. A display without a notch gets `cameraWidth` 0.
    public static func geometry(for screen: NSScreen) -> NotchGeometry {
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        guard let notch = screen.physicalNotchRect else {
            return NotchGeometry(screenFrame: screen.frame, cameraWidth: 0, topInset: menuBar)
        }
        return NotchGeometry(screenFrame: screen.frame, cameraWidth: notch.width, topInset: notch.height)
    }

    // MARK: Lifecycle

    /// Turns the notch on with the enabled widgets in saved order. Calling it
    /// again updates the widgets and re-resolves the display.
    public func start(widgets: [Widget]) {
        setWidgets(widgets)
        guard !started else { resolveScreen(); return }
        started = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScreenRetries() }
            },
        ]
        resolveScreen()
        scheduleScreenRetries()
    }

    /// Turns the notch off. An open widget is dismissed first, then both
    /// windows are released.
    public func stop() {
        guard started else { return }
        started = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        screenTask?.cancel(); screenTask = nil
        tearDown()
    }

    /// Locking hides the notch and dismisses any widget.
    public func setSessionLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked { tearDown() } else if started { resolveScreen() }
    }

    public func setWidgets(_ newWidgets: [Widget]) {
        var seen = Set<Widget>()
        widgets = newWidgets.filter { seen.insert($0).inserted }
        viewModel.setWidgets(widgets)
        syncCompanion()
    }

    public func updateActivity(_ activity: ActivityItem?, artwork: NSImage?, queueCount: Int, restorableCount: Int) {
        viewModel.setActivity(activity, artwork: artwork)
    }

    /// Duo view: Now Playing beside Calendar. The parent sends true only when
    /// the saved switch is on, Calendar access is allowed, the widget is
    /// enabled and the agenda has a relevant event.
    public func setDuo(_ requested: Bool) {
        guard requested != isDuoRequested else { return }
        isDuoRequested = requested
        viewModel.duoActive = requested
        syncCompanion()
    }

    /// Every widget shares one fixed footprint, so late content needs no refit.
    public func contentDidChange(_ widget: Widget) {}

    public func setShowInFullscreen(_ show: Bool) {
        showsInFullscreen = show
        window?.setShowInFullscreen(show)
        hoverPanel?.setShowInFullscreen(show)
    }

    public func setHover(enabled: Bool, closeDelay: TimeInterval) {
        viewModel.expansionTrigger = enabled ? .hover : .click
        viewModel.hoverCloseDelay = closeDelay.isFinite
            ? min(max(closeDelay, Self.closeDelayRange.lowerBound), Self.closeDelayRange.upperBound) : 0.4
    }

    public func setAppearance(_ value: Appearance) {
        switch value {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .system: appearance = nil
        }
        window?.appearance = appearance
        hostingView?.appearance = appearance
    }

    // MARK: Open and close

    /// Opens a widget, or the last used one. Nothing happens while the notch
    /// is not presenting.
    public func expand(_ widget: Widget? = nil, focus: Bool = false) {
        guard isPresenting else { return }
        viewModel.expand(widget)
    }

    /// The notch shortcut: the same toggle as a click.
    public func toggle() {
        guard isPresenting else { return }
        viewModel.hotkeyToggled()
    }

    public func collapse() {
        guard isPresenting else { return }
        viewModel.collapse()
    }

    // MARK: Widget lifetime

    private func present(from: Widget?, to: Widget) {
        if companion != nil, to != .nowPlaying { releaseCompanion() }
        callbacks.willShowWidget(from, to)
        primaryController = nil
        primaryWidget = to
        primaryController = callbacks.makeWidget(to)
        syncCompanion()
    }

    private func dismiss(_ widget: Widget) {
        callbacks.willDismissWidget(widget)
        primaryController = nil
        primaryWidget = nil
        releaseCompanion()
    }

    private func syncCompanion() {
        let wanted = primaryWidget == .nowPlaying && isDuoRequested && widgets.contains(.calendar)
        if wanted, companion == nil {
            companion = .calendar
            callbacks.companionChanged(.calendar)
            companionController = callbacks.makeWidget(.calendar)
        } else if !wanted, companion != nil {
            releaseCompanion()
        }
    }

    private func releaseCompanion() {
        guard companion != nil else { return }
        companionController = nil
        companion = nil
        callbacks.companionChanged(nil)
    }

    private func content(for widget: Widget) -> AnyView? {
        let controller: NSViewController?
        if widget == primaryWidget { controller = primaryController }
        else if widget == companion { controller = companionController }
        else { controller = nil }
        guard let controller else { return nil }
        if let provider = controller as? NotchContentProviding { return provider.notchContent() }
        return AnyView(NotchControllerView(controller: controller))
    }

    // MARK: Screen

    private func screenParametersChanged() {
        guard started else { return }
        resolveScreen()
        scheduleScreenRetries()
    }

    /// AppKit can post the screen notification before the notch areas settle,
    /// so discovery retries a few times over about ten seconds.
    private func scheduleScreenRetries() {
        screenTask?.cancel()
        guard started else { return }
        screenTask = Task { @MainActor [weak self] in
            for delay in Self.screenRetryDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.started else { return }
                self.resolveScreen()
                if self.isPresenting { return }
            }
        }
    }

    private func resolveScreen() {
        guard started, !isLocked, let (screen, notchRect) = resolveNotch() else {
            if started, !isLocked, isPresenting { losePresentation() }
            return
        }
        let window = window ?? makeWindow()
        let bounds = NotchMetrics.panelBounds(for: notchRect.width)
        let frame = NSRect(x: notchRect.midX - bounds.width / 2, y: screen.frame.maxY - bounds.height,
                           width: bounds.width, height: bounds.height)
        // A refresh on the same display keeps the live view and its animation.
        let changed = notchRect != physicalNotchRect || window.frame != frame
        if changed || !isPresenting {
            physicalNotchRect = notchRect
            window.setFrame(frame, display: true)
            hostingView?.rootView = makeRootView(notchRect: notchRect, panelFrame: window.frame)
        }
        if !window.isVisible { window.orderFrontRegardless() }
        let wasPresenting = isPresenting
        isPresenting = true
        guard changed || !wasPresenting else { return }
        updatePresentation()
        updatePassThrough(for: viewModel.state)
        if case .collapsed = viewModel.state { refreshHover() }
    }

    /// The notch's display went away: collapse and order out, keep the windows.
    private func losePresentation() {
        isPresenting = false
        physicalNotchRect = .null
        removePointerMonitors()
        removeCollapsedClickMonitors()
        hoverPanel?.orderOut(nil)
        window?.orderOut(nil)
        viewModel.forceCollapse()
        updatePresentation()
    }

    private func tearDown() {
        isPresenting = false
        removePointerMonitors()
        removeCollapsedClickMonitors()
        resampleTask?.cancel(); resampleTask = nil
        viewModel.forceCollapse()
        hoverPanel?.orderOut(nil)
        hoverPanel = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        hostingView = nil
        physicalNotchRect = .null
        dragSessionEntered = false
        updatePresentation()
    }

    private func makeWindow() -> NotchWindow {
        let window = NotchWindow(viewModel: viewModel)
        window.appearance = appearance
        window.setShowInFullscreen(showsInFullscreen)
        let hosting = NotchHostingView(viewModel: viewModel, rootView: makeRootView(notchRect: .zero, panelFrame: .zero))
        hosting.appearance = appearance
        window.contentView = hosting
        hostingView = hosting
        window.onDraggingMoved = { [weak self, weak window] info in
            // A tile dragged out of the open shelf is never dropped back onto it.
            if let source = info.draggingSource as? NSView, source.window === window { return [] }
            return self?.draggingUpdated(at: info.draggingLocation) ?? []
        }
        window.onDraggingExited = { [weak self] in self?.draggingExited() }
        window.onPerformDragOperation = { [weak self] pasteboard in self?.performDrag(pasteboard) ?? false }
        self.window = window
        return window
    }

    private func makeRootView(notchRect: CGRect, panelFrame: CGRect) -> AnyView {
        let collapsed = NotchMetrics.collapsedFrame(notchRect: notchRect, panelFrame: panelFrame)
        return AnyView(NotchRootView(viewModel: viewModel, notchSize: notchRect.size,
                                     collapsedFrame: collapsed.width > 0 ? collapsed : nil))
    }

    private func stateChanged(_ state: NotchState) {
        updatePresentation()
        updatePassThrough(for: state)
    }

    private func updatePresentation() {
        guard isPresenting else { presentation = .hidden; return }
        switch viewModel.state {
        case .collapsed, .activity: presentation = .compact
        case .expanded(let widget): presentation = .expanded(widget)
        }
    }

    // MARK: Pass-through and hover

    private func updatePassThrough(for state: NotchState) {
        guard let window, isPresenting else {
            removePointerMonitors()
            removeCollapsedClickMonitors()
            hoverPanel?.orderOut(nil)
            return
        }
        installPointerMonitors()
        let wasIgnoring = window.ignoresMouseEvents
        window.ignoresMouseEvents = Self.shouldIgnoreMouseEvents(
            state: state, pointInsideVisibleShape: pointerInsideVisibleShape(for: state, at: NSEvent.mouseLocation))
        switch state {
        case .collapsed: installCollapsedClickMonitors()
        case .activity, .expanded: removeCollapsedClickMonitors()
        }
        syncHoverPanel(for: state)
        if wasIgnoring != window.ignoresMouseEvents { window.resetGestureState() }
        if case .collapsed = state { return }
        // Re-sample once on the next turn, so a panel opened under a pointer
        // that is already outside its new shape still closes.
        resampleTask?.cancel()
        resampleTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isPresenting else { return }
            self.resampleTask = nil
            self.handleMonitoredMove(at: NSEvent.mouseLocation)
        }
    }

    private func syncHoverPanel(for state: NotchState) {
        guard Self.shouldShowCollapsedHoverPanel(state: state, isPresenting: isPresenting),
              !physicalNotchRect.isNull else {
            hoverPanel?.orderOut(nil)
            return
        }
        let panel = hoverPanel ?? makeHoverPanel()
        let rect = Self.collapsedHoverPanelRect(notchRect: physicalNotchRect)
        guard !rect.isNull else { panel.orderOut(nil); return }
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    private func makeHoverPanel() -> NotchHoverPanel {
        let panel = NotchHoverPanel(
            onMove: { [weak self] location in self?.handleMonitoredMove(at: location) },
            onClick: { [weak self] location, flags in
                self?.handleHoverPanelClick(at: location, optionDown: flags.contains(.option))
            })
        panel.setShowInFullscreen(showsInFullscreen)
        hoverPanel = panel
        return panel
    }

    private func installPointerMonitors() {
        guard !pointerMonitorsInstalled else { return }
        pointerMonitorsInstalled = true
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleMonitoredMove(at: location) }
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMonitoredMove(at: NSEvent.mouseLocation) }
            return event
        }
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.handleRightClick(at: location) }
        }
        localRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleRightClick(at: NSEvent.mouseLocation) }
            return event
        }
    }

    private func removePointerMonitors() {
        let monitors = [globalMoveMonitor, localMoveMonitor, globalRightClickMonitor, localRightClickMonitor].compactMap { $0 }
        if !monitors.isEmpty {
            nonisolated(unsafe) let pending = monitors
            DispatchQueue.main.async { pending.forEach { NSEvent.removeMonitor($0) } }
        }
        globalMoveMonitor = nil; localMoveMonitor = nil
        globalRightClickMonitor = nil; localRightClickMonitor = nil
        pointerMonitorsInstalled = false
        viewModel.resetHoverState()
    }

    private func installCollapsedClickMonitors() {
        guard !collapsedClickMonitorsInstalled else { return }
        collapsedClickMonitorsInstalled = true
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let location = NSEvent.mouseLocation
            let optionDown = event.modifierFlags.contains(.option)
            Task { @MainActor in self?.handleMonitoredClick(at: location, optionDown: optionDown) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let optionDown = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.handleMonitoredClick(at: NSEvent.mouseLocation, optionDown: optionDown) }
            return event
        }
    }

    /// Removal waits one turn: the local monitor can be on the stack here.
    private func removeCollapsedClickMonitors() {
        let monitors = [globalClickMonitor, localClickMonitor].compactMap { $0 }
        globalClickMonitor = nil; localClickMonitor = nil
        collapsedClickMonitorsInstalled = false
        guard !monitors.isEmpty else { return }
        nonisolated(unsafe) let pending = monitors
        DispatchQueue.main.async { pending.forEach { NSEvent.removeMonitor($0) } }
    }

    // MARK: Geometry rules (0.21.35, pure)

    static func collapsedHoverRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return CGRect(x: rect.minX - hoverSlopX, y: rect.minY - hoverSlopBelow,
                      width: rect.width + hoverSlopX * 2, height: rect.height + hoverSlopBelow)
    }

    static func collapsedClickRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return CGRect(x: rect.minX - clickSlopX, y: rect.minY, width: rect.width + clickSlopX * 2, height: rect.height)
    }

    static func collapsedHoverPanelRect(notchRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return rect
    }

    static func collapsedHoverPanelOwnsClick(notchRect rect: CGRect, point: CGPoint, isVisible: Bool) -> Bool {
        guard isVisible else { return false }
        return collapsedHoverPanelRect(notchRect: rect).contains(point)
    }

    static func shouldShowCollapsedHoverPanel(state: NotchState, isPresenting: Bool) -> Bool {
        guard isPresenting else { return false }
        if case .collapsed = state { return true }
        return false
    }

    static func shouldAcceptMonitoredInput(isPresenting: Bool, mainWindowVisible: Bool, triggerWindowVisible: Bool,
                                           showInFullscreen: Bool, mainWindowOnActiveSpace: Bool,
                                           triggerWindowOnActiveSpace: Bool) -> Bool {
        guard isPresenting, mainWindowVisible || triggerWindowVisible else { return false }
        if showInFullscreen { return true }
        return (mainWindowVisible && mainWindowOnActiveSpace) || (triggerWindowVisible && triggerWindowOnActiveSpace)
    }

    static func openHoverRect(interactiveRect rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        return rect.insetBy(dx: -openHoverSlop, dy: -openHoverSlop)
    }

    static func shouldIgnoreMouseEvents(state: NotchState, pointInsideVisibleShape: Bool) -> Bool {
        switch state {
        case .collapsed: return true
        case .activity, .expanded: return !pointInsideVisibleShape
        }
    }

    static func shouldAcceptDrag(state: NotchState, pointInNotch: Bool, shelfEnabled: Bool) -> Bool {
        switch state {
        case .collapsed: return shelfEnabled && pointInNotch
        case .expanded(.shelf): return pointInNotch
        default: return false
        }
    }

    /// Screen point to the panel's top-left space, where `interactiveRect` lives.
    private func notchSpacePoint(_ screenPoint: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        return NSPoint(x: screenPoint.x - window.frame.minX, y: window.frame.maxY - screenPoint.y)
    }

    private func isHovering(screenPoint: NSPoint) -> Bool {
        switch viewModel.state {
        case .collapsed:
            return Self.collapsedHoverRect(notchRect: physicalNotchRect).contains(screenPoint)
        case .activity, .expanded:
            guard let local = notchSpacePoint(screenPoint) else { return false }
            return Self.openHoverRect(interactiveRect: viewModel.interactiveRect).contains(local)
        }
    }

    private func pointerInsideVisibleShape(for state: NotchState, at screenPoint: NSPoint) -> Bool {
        switch state {
        case .collapsed: return false
        case .activity, .expanded:
            guard let local = notchSpacePoint(screenPoint) else { return false }
            return viewModel.interactiveRect.contains(local)
        }
    }

    private func updateMouseCapture(at location: NSPoint) {
        guard let window, isPresenting else { return }
        let shouldIgnore = Self.shouldIgnoreMouseEvents(
            state: viewModel.state, pointInsideVisibleShape: pointerInsideVisibleShape(for: viewModel.state, at: location))
        guard window.ignoresMouseEvents != shouldIgnore else { return }
        window.ignoresMouseEvents = shouldIgnore
        window.resetGestureState()
    }

    private var isOverlayVisible: Bool {
        Self.shouldAcceptMonitoredInput(
            isPresenting: isPresenting,
            mainWindowVisible: window?.isVisible == true,
            triggerWindowVisible: hoverPanel?.isVisible == true,
            showInFullscreen: showsInFullscreen,
            mainWindowOnActiveSpace: window?.isOnActiveSpace == true,
            triggerWindowOnActiveSpace: hoverPanel?.isOnActiveSpace == true)
    }

    private func handleMonitoredMove(at location: NSPoint) {
        guard isPresenting, isOverlayVisible, !isShowingMenu else { return }
        updateMouseCapture(at: location)
        viewModel.hoverChanged(inside: isHovering(screenPoint: location))
    }

    private func refreshHover() {
        guard isPresenting, isOverlayVisible else { return }
        let location = NSEvent.mouseLocation
        updateMouseCapture(at: location)
        viewModel.resyncHover(inside: isHovering(screenPoint: location))
    }

    private func handleMonitoredClick(at location: NSPoint, optionDown: Bool) {
        guard isPresenting, isOverlayVisible, !isShowingMenu, case .collapsed = viewModel.state,
              Self.collapsedClickRect(notchRect: physicalNotchRect).contains(location) else { return }
        guard !Self.collapsedHoverPanelOwnsClick(notchRect: physicalNotchRect, point: location,
                                                 isVisible: hoverPanel?.isVisible == true) else { return }
        viewModel.clicked(optionDown: optionDown)
    }

    private func handleHoverPanelClick(at location: NSPoint, optionDown: Bool) {
        guard isPresenting, isOverlayVisible, !isShowingMenu, case .collapsed = viewModel.state,
              Self.collapsedHoverPanelOwnsClick(notchRect: physicalNotchRect, point: location, isVisible: true) else { return }
        viewModel.clicked(optionDown: optionDown)
    }

    /// A right-click on the physical notch, in any state, shows the app menu.
    private func handleRightClick(at location: NSPoint) {
        guard isPresenting, isOverlayVisible, !isShowingMenu,
              Self.collapsedHoverPanelRect(notchRect: physicalNotchRect).contains(location),
              let menu = callbacks.contextMenu() else { return }
        isShowingMenu = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                menu.popUp(positioning: nil, at: location, in: nil)
                guard let self else { return }
                self.isShowingMenu = false
                self.refreshHover()
            }
        }
    }

    // MARK: File drags

    private func draggingUpdated(at windowLocation: NSPoint) -> NSDragOperation {
        guard let window, isPresenting else { return [] }
        let local = NSPoint(x: windowLocation.x, y: window.frame.height - windowLocation.y)
        let pointInNotch: Bool
        switch viewModel.state {
        case .collapsed:
            pointInNotch = viewModel.interactiveRect.insetBy(dx: -Self.dragSlop, dy: -Self.dragSlop).contains(local)
        case .expanded(.shelf):
            pointInNotch = viewModel.interactiveRect.contains(local)
        default:
            pointInNotch = false
        }
        guard Self.shouldAcceptDrag(state: viewModel.state, pointInNotch: pointInNotch,
                                    shelfEnabled: widgets.contains(.shelf)) else { return [] }
        if viewModel.state == .collapsed, !dragSessionEntered {
            dragSessionEntered = true
            viewModel.dragEntered()
        }
        return .copy
    }

    private func draggingExited() {
        dragSessionEntered = false
        viewModel.dragExited()
    }

    private func performDrag(_ pasteboard: NSPasteboard) -> Bool {
        defer {
            dragSessionEntered = false
            viewModel.dragCompleted()
        }
        guard widgets.contains(.shelf),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        return callbacks.shelfDrop(urls)
    }
}

/// Hosts a plain widget controller's view inside the SwiftUI root.
private struct NotchControllerView: NSViewRepresentable {
    let controller: NSViewController

    func makeNSView(context: Context) -> NSView { controller.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
