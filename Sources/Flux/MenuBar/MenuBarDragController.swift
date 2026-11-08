import AppKit
import ApplicationServices
import Combine

@MainActor
final class MenuBarDragController: ObservableObject {
    static let pasteboardType = NSPasteboard.PasteboardType("com.bdwy.flux.menu-bar-icon")
    @Published private(set) var message: String?
    @Published private(set) var isDragging = false
    private(set) var diagnostics = "none"
    var trace: ((String) -> Void)?
    var onWindowClose: (() -> Void)?
    private weak var manager: MenuBarIconManager?
    private weak var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var updateObservation: AnyCancellable?
    private var updatingIcons = false
    private var escapeMonitor: Any?
    private var generation = 0
    private var displays: [Display] = []
    private struct Display: Equatable {
        let id: UInt32
        let frame: CGRect
        let scale: CGFloat
        let topInset: CGFloat
    }
    private static func currentDisplays() -> [Display] {
        NSScreen.screens.map {
            Display(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                    frame: $0.frame, scale: $0.backingScaleFactor, topInset: $0.safeAreaInsets.top)
        }
    }
    private var active: (token: String, icon: MenuBarIconManager.Icon)?
    private struct Drop {
        let generation: Int
        let icon: MenuBarIconManager.Icon
        let section: MenuBarSection
        let insertion: MenuBarIconManager.Insertion?
    }
    private var pending: Drop?
    var draggedIconID: String? { active?.icon.id }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func open(manager: MenuBarIconManager, window: NSWindow) {
        guard settingsWindow !== window || self.manager !== manager else { return }
        close()
        self.manager = manager
        settingsWindow = window
        displays = Self.currentDisplays()
        updateObservation = manager.$isUpdatingIcons.sink { [weak self] updating in
            MainActor.assumeIsolated { self?.updatingIcons = updating }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didChangeScreenParametersNotification {
                        let current = Self.currentDisplays()
                        guard self.displays != current else { return }
                        self.displays = current
                    }
                    self.invalidate(reason: name == NSApplication.didResignActiveNotification
                                    ? .focusLost : .screenChanged)
                }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.onWindowClose?() }
                    self?.invalidate(reason: name == NSWindow.didResignKeyNotification ? .focusLost : .closed)
                }
            })
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.invalidate(reason: .escape) } }
            return event
        }
    }

    func close() {
        invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        updateObservation = nil
        updatingIcons = false
        manager = nil
        settingsWindow = nil
    }

    private func invalidate(reason: MenuBarIconManager.MoveCancellation = .closed) {
        generation += 1
        active = nil
        pending = nil
        isDragging = false
        manager?.cancelPendingMoves(for: reason)
    }

    func refreshIcons() {
        guard !isDragging, !updatingIcons else { return }
        message = nil
        manager?.refresh()
    }

    func makeSourceView(for icon: MenuBarIconManager.Icon) -> MenuBarDragSourceView {
        let view = MenuBarDragSourceView(frame: .zero)
        view.controller = self
        view.icon = icon
        return view
    }

    private func sameItem(_ lhs: MenuBarIconManager.Icon, _ rhs: MenuBarIconManager.Icon) -> Bool {
        lhs.id == rhs.id && lhs.identity == rhs.identity && lhs.isMovable && rhs.isMovable
    }

    private func handleDescription(_ icon: MenuBarIconManager.Icon?) -> String {
        guard let icon else { return "missing" }
        return "\(icon.id) identity=\(icon.identity?.uuidString ?? "none")"
    }

    func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard canManage, !updatingIcons, let active,
              sender.draggingSource is MenuBarDragSourceView,
              sender.draggingSourceOperationMask.contains(.move),
              sender.draggingPasteboard.string(forType: Self.pasteboardType) == active.token else { return false }
        return true
    }

    func performDrop(_ sender: NSDraggingInfo, to section: MenuBarSection,
                     insertion: MenuBarIconManager.Insertion? = nil) -> Bool {
        guard accepts(sender), let active, let manager else { return false }
        diagnostics += "; drop source=\(handleDescription(active.icon))"
        guard let current = manager.icons.first(where: { sameItem($0, active.icon) }),
              insertion == nil || insertion?.section == section else {
            diagnostics += "; rejected source, current=\(handleDescription(manager.icons.first { $0.id == active.icon.id }))"
            message = "That icon changed. Try the move again."
            return false
        }
        if let insertion {
            let peers = manager.icons.filter { $0.section == section && $0.id != current.id }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard insertion.matches(peers) else {
                diagnostics += "; rejected destination"
                message = "The destination changed. Try the move again."
                return false
            }
        }
        pending = Drop(generation: generation, icon: current, section: section, insertion: insertion)
        diagnostics += "; staged \(section.rawValue)"
        message = nil
        trace?("staged \(section.rawValue) \(current.id)")
        return true
    }

    fileprivate func begin(icon: MenuBarIconManager.Icon, in view: MenuBarDragSourceView,
                           mouseDown: NSEvent) -> NSDraggingSession? {
        guard canManage, !updatingIcons, active == nil, let manager,
              !mouseDown.modifierFlags.contains(.command) else { return nil }
        diagnostics = "begin source=\(handleDescription(icon)); current=\(handleDescription(manager.icons.first { $0.id == icon.id }))"
        guard mouseDown.type == .leftMouseDown,
              let current = manager.icons.first(where: { sameItem($0, icon) }) else {
            diagnostics += "; rejected source"
            message = "That icon changed. Try the move again."
            return nil
        }
        let token = UUID().uuidString
        active = (token, current)
        pending = nil
        isDragging = true
        let writer = NSPasteboardItem()
        writer.setString(token, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { bitmap -> NSImage in
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            return image
        } ?? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: current.title)!
        item.setDraggingFrame(view.bounds, contents: image)
        let session = view.beginDraggingSession(with: [item], event: mouseDown, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
        trace?("begin window=\(mouseDown.windowNumber) source=\(view.window?.windowNumber ?? -1)")
        return session
    }

    fileprivate func ended(operation: NSDragOperation) {
        diagnostics += "; ended=\(operation.rawValue)"
        trace?("ended operation=\(operation.rawValue)")
        let drop = pending
        pending = nil
        active = nil
        isDragging = false
        guard operation.contains(.move), let drop else { return }
        Task { [weak self] in
            await Task.yield()
            guard let self, self.generation == drop.generation, self.canManage,
                  let manager = self.manager else { return }
            if let insertion = drop.insertion {
                let accepted = manager.move(drop.icon, to: insertion) { [weak self] current in
                    guard let self else { return false }
                    return self.generation == drop.generation && self.canManage && self.sameItem(current, drop.icon)
                }
                if !accepted { self.message = "That icon or destination changed. Try the move again." }
            } else {
                manager.move(drop.icon, to: drop.section)
            }
            self.trace?("commit \(drop.section.rawValue) \(drop.icon.id)")
        }
    }

    private var canManage: Bool {
        guard let settingsWindow, let manager else { return false }
        return manager.isTrusted && NSApp.isActive && settingsWindow.isVisible
            && !settingsWindow.isMiniaturized && NSApp.keyWindow === settingsWindow
    }
}

@MainActor
final class MenuBarDragSourceView: NSView, NSDraggingSource {
    weak var controller: MenuBarDragController?
    var icon: MenuBarIconManager.Icon? {
        didSet {
            if oldValue?.id != icon?.id {
                appImage = icon.flatMap { icon in
                    let bundleID = String(icon.id.split(separator: "|").first ?? "")
                    if let image = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon { return image }
                    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                        NSWorkspace.shared.icon(forFile: $0.path)
                    }
                }
            }
            needsDisplay = true
        }
    }
    private var appImage: NSImage?
    var imageProvider: (() -> NSImage?)?
    var menuBarImage: NSImage? { imageProvider?() }
    private var down: NSEvent?
    var moveMenu: (() -> NSMenu?)?
    override var acceptsFirstResponder: Bool { icon?.isMovable == true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event.modifierFlags.contains(.command) ? nil : event
        controller?.trace?("source down command=\(event.modifierFlags.contains(.command))")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let icon, !event.modifierFlags.contains(.command) else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        self.down = nil
        _ = controller?.begin(icon: icon, in: self, mouseDown: down)
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = down != nil && !event.modifierFlags.contains(.command)
        down = nil
        if clicked { showMoveMenu() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(nil) }
            else { window?.selectNextKeyView(nil) }
        case 36, 49, 125: showMoveMenu()
        case 123: window?.selectPreviousKeyView(nil)
        case 124: window?.selectNextKeyView(nil)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { showMoveMenu() }

    @discardableResult private func showMoveMenu() -> Bool {
        guard icon?.isMovable == true, let menu = moveMenu?() else { return false }
        window?.makeFirstResponder(self)
        return menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { moveMenu?() }

    override func becomeFirstResponder() -> Bool {
        scrollToVisible(bounds)
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        controller?.trace?("native began window=\(window?.windowNumber ?? -1) point=\(screenPoint)")
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        controller?.trace?("native moved point=\(screenPoint)")
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        down = nil
        controller?.ended(operation: operation)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if icon?.isMovable == true { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon else { return }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
        let image = menuBarImage ?? appImage ?? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        if let image {
            let size = menuBarImage?.size ?? NSSize(width: 22, height: 22)
            let scale = min(1, min((bounds.width - 12) / max(1, size.width), 26 / max(1, size.height)))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                                 width: drawn.width, height: drawn.height))
        }
        if !icon.isMovable {
            NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .draw(in: NSRect(x: bounds.maxX - 10, y: 3, width: 7, height: 8))
        }
    }
}

@MainActor
class MenuBarDragDestinationView: NSView {
    weak var controller: MenuBarDragController?
    var section: MenuBarSection = .shown
    var acceptsDrops = true
    var insertionAt: ((NSPoint) -> MenuBarIconManager.Insertion?)?
    var markerAt: ((NSPoint) -> CGFloat)?
    private var markerX: CGFloat?
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([MenuBarDragController.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = acceptsDrops && controller?.accepts(sender) == true
        markerX = targeted ? markerAt?(convert(sender.draggingLocation, from: nil)) : nil
        controller?.trace?("entered \(section.rawValue) valid=\(targeted)")
        return targeted ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = acceptsDrops && controller?.accepts(sender) == true
        markerX = targeted ? markerAt?(convert(sender.draggingLocation, from: nil)) : nil
        controller?.trace?("updated \(section.rawValue) valid=\(targeted) scroll=\(enclosingScrollView != nil)")
        if targeted, let scroll = enclosingScrollView {
            let clip = scroll.contentView
            let point = clip.convert(sender.draggingLocation, from: nil)
            var bounds = clip.bounds
            controller?.trace?("viewport point=\(point) bounds=\(bounds) location=\(sender.draggingLocation)")
            if scroll.hasVerticalScroller {
                if point.y < bounds.minY + 24 { bounds.origin.y -= 18 }
                else if point.y > bounds.maxY - 24 { bounds.origin.y += 18 }
            }
            if scroll.hasHorizontalScroller {
                if point.x < bounds.minX + 28 { bounds.origin.x -= 18 }
                else if point.x > bounds.maxX - 28 { bounds.origin.x += 18 }
            }
            if bounds != clip.bounds {
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(clip)
                controller?.trace?("scroll point=\(point) requested=\(bounds) actual=\(clip.bounds)")
            }
        }
        return targeted ? .move : []
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false; markerX = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = acceptsDrops && controller?.accepts(sender) == true
        controller?.trace?("prepared \(section.rawValue) valid=\(accepted)")
        return accepted
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        let insertion = insertionAt?(convert(sender.draggingLocation, from: nil))
        let committed = acceptsDrops && controller?.performDrop(sender, to: section, insertion: insertion) == true
        controller?.trace?("performed \(section.rawValue) valid=\(committed)")
        return committed
    }

    override func draw(_ dirtyRect: NSRect) {
        guard targeted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        border.lineWidth = 2
        border.stroke()
        if let markerX {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: markerX - 1.5, y: 8, width: 3, height: bounds.height - 16),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
