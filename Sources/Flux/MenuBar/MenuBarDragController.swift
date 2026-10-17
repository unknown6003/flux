import AppKit
import ApplicationServices
import Combine

@MainActor
final class MenuBarDragController: ObservableObject {
    static let pasteboardType = NSPasteboard.PasteboardType("com.bdwy.flux.menu-bar-icon")

    @Published private(set) var message: String?
    @Published private(set) var isDragging = false
    var trace: ((String) -> Void)?
    var onWindowClose: (() -> Void)?

    private weak var manager: MenuBarIconManager?
    private weak var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var updateObservation: AnyCancellable?
    private var updatingIcons = false
    private var active: (token: String, icon: MenuBarIconManager.Icon, identity: MenuBarDragIdentity)?
    var draggedIconID: String? { active?.icon.id }
    private struct DisplayGeometry: Equatable {
        let id: UInt32
        let frame: CGRect
        let scale: CGFloat
        let safeArea: [CGFloat]
    }
    private var displayGeometry: [DisplayGeometry] = []

    private static func currentDisplayGeometry() -> [DisplayGeometry] {
        NSScreen.screens.map {
            DisplayGeometry(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                            frame: $0.frame, scale: $0.backingScaleFactor,
                            safeArea: [$0.safeAreaInsets.top, $0.safeAreaInsets.left, $0.safeAreaInsets.bottom, $0.safeAreaInsets.right])
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func open(manager: MenuBarIconManager, window: NSWindow) {
        guard settingsWindow !== window || self.manager !== manager else { return }
        close()
        self.manager = manager
        settingsWindow = window
        displayGeometry = Self.currentDisplayGeometry()
        updateObservation = manager.$isUpdatingIcons.sink { [weak self] updating in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatingIcons = updating
                if updating, self.active == nil, self.message != nil { self.message = nil }
            }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSApplication.didChangeScreenParametersNotification, let self {
                        let current = Self.currentDisplayGeometry()
                        guard current != self.displayGeometry else { return }
                        self.displayGeometry = current
                    }
                    self?.trace?("cancel notification=\(name.rawValue)")
                    self?.cancel()
                }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.onWindowClose?() }
                    self?.trace?("cancel notification=\(name.rawValue)")
                    self?.cancel()
                }
            })
        }
    }

    func close() {
        trace?("close settings")
        cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        updateObservation = nil
        updatingIcons = false
        manager = nil
        settingsWindow = nil
    }

    func refreshIcons() {
        guard active == nil, !updatingIcons else { return }
        message = nil
        manager?.refresh()
    }

    func makeSourceView(for icon: MenuBarIconManager.Icon) -> MenuBarDragSourceView {
        let view = MenuBarDragSourceView(frame: .zero)
        view.controller = self
        view.icon = icon
        return view
    }

    func accepts(_ sender: NSDraggingInfo) -> Bool {
        trace?("accept managed=\(canManage) busy=\(updatingIcons) active=\(active != nil) source=\(sender.draggingSource is MenuBarDragSourceView) token=\(sender.draggingPasteboard.string(forType: Self.pasteboardType) == active?.token)")
        guard canManage, !updatingIcons, let active,
              sender.draggingSource as? MenuBarDragSourceView != nil,
              sender.draggingSourceOperationMask.contains(.move),
              sender.draggingPasteboard.string(forType: Self.pasteboardType) == active.token else { return false }
        return true
    }

    func performDrop(_ sender: NSDraggingInfo, to section: MenuBarSection,
                     insertion: MenuBarIconManager.Insertion? = nil) -> Bool {
        guard accepts(sender), let pending = active, let manager, AXIsProcessTrusted() else { return false }
        if let insertion {
            guard insertion.section == section else { return false }
            let accepted = manager.move(pending.icon, to: insertion) { [weak self] current in
                guard let self else { return false }
                return self.canManage && self.active?.token == pending.token
                    && current.frame == pending.icon.frame && pending.identity.isCurrent(for: current)
            }
            cancel()
            message = accepted ? nil : "That icon or destination changed. Refresh icons and try again."
            trace?(accepted ? "commit \(section.rawValue) \(pending.icon.id)" : "drop rejected identity or destination")
            return accepted
        }
        manager.refresh()
        let matches = manager.icons.filter { $0.id == pending.icon.id }
        guard canManage, active?.token == pending.token, matches.count == 1,
              let current = matches.first, current.isMovable,
              current.title == pending.icon.title, current.source == pending.icon.source,
              current.frame == pending.icon.frame, pending.identity.isCurrent(for: current) else {
            cancel()
            message = "That icon changed during the drag. Refresh icons and try again."
            trace?("drop rejected identity")
            return false
        }
        cancel()
        message = nil
        trace?("commit \(section.rawValue) \(current.id)")
        manager.move(current, to: section)
        return true
    }

    fileprivate func begin(icon: MenuBarIconManager.Icon, in view: MenuBarDragSourceView,
                           mouseDown: NSEvent) -> NSDraggingSession? {
        guard canManage, !updatingIcons, icon.isMovable, active == nil,
              let manager, AXIsProcessTrusted() else { return nil }
        let matches = manager.icons.filter { $0.id == icon.id }
        guard matches.count == 1, let current = matches.first, current == icon,
              let identity = MenuBarDragIdentity(icon: current) else {
            message = "That icon changed. Refresh icons and try again."
            return nil
        }
        guard canManage, !updatingIcons,
              CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) else { return nil }
        let token = UUID().uuidString
        active = (token, current, identity)
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
        trace?("ended operation=\(operation.rawValue)")
        cancel()
    }

    private func cancel() {
        active = nil
        if isDragging { isDragging = false }
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

@MainActor
private struct MenuBarDragIdentity {
    let owner: NSRunningApplication
    let launched: Date?
    let elements: [AXUIElement]
    let element: AXUIElement
    let index: Int
    let barAttribute: String

    init?(icon: MenuBarIconManager.Icon) {
        let apps: [NSRunningApplication]
        let attribute: String
        let expectedIndex: Int?
        if ControlItem.usesMacOS27Model {
            guard let identity = MenuBarIconManager.appIconIdentity(from: icon.id) else { return nil }
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID)
                .filter { $0.processIdentifier == identity.processID }
            attribute = kAXExtrasMenuBarAttribute
            expectedIndex = identity.index
        } else {
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver")
            attribute = kAXMenuBarAttribute
            expectedIndex = nil
        }
        guard apps.count == 1, let owner = apps.first,
              expectedIndex == nil || MenuBarIconManager.launchToken(for: owner.launchDate)
                == MenuBarIconManager.appIconIdentity(from: icon.id)?.launchToken,
              let elements = Self.items(owner: owner, attribute: attribute) else { return nil }
        let matches = elements.enumerated().filter {
            Self.matches($0.element, icon: icon, owner: owner, index: $0.offset)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        if let expectedIndex, match.offset != expectedIndex { return nil }
        self.owner = owner
        launched = owner.launchDate
        self.elements = elements
        element = match.element
        index = match.offset
        barAttribute = attribute
    }

    func isCurrent(for icon: MenuBarIconManager.Icon) -> Bool {
        guard !owner.isTerminated, owner.launchDate == launched,
              let current = Self.items(owner: owner, attribute: barAttribute),
              current.count == elements.count, current.indices.contains(index),
              zip(current, elements).allSatisfy({ CFEqual($0.0, $0.1) }),
              CFEqual(current[index], element),
              Self.matches(current[index], icon: icon, owner: owner, index: index) else { return false }
        return current.enumerated().filter {
            Self.matches($0.element, icon: icon, owner: owner, index: $0.offset)
        }.count == 1
    }

    private static func items(owner: NSRunningApplication, attribute: String) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let value = read(app, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let bar = value as! AXUIElement
        return read(bar, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func matches(_ element: AXUIElement, icon: MenuBarIconManager.Icon,
                                owner: NSRunningApplication, index: Int) -> Bool {
        let fallback = ControlItem.usesMacOS27Model
            ? owner.localizedName ?? owner.bundleIdentifier : "Menu bar item \(index + 1)"
        let title = nonemptyString(element, kAXTitleAttribute)
            ?? nonemptyString(element, kAXDescriptionAttribute)
            ?? fallback
        guard title == icon.title,
              let p = read(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = read(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return false }
        return CGRect(origin: point, size: size) == icon.frame
    }

    private static func nonemptyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let text = read(element, attribute) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
