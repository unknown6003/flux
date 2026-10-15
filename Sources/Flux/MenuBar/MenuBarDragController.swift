import AppKit
import ApplicationServices
import Combine

@MainActor
final class MenuBarDragController: ObservableObject {
    static let pasteboardType = NSPasteboard.PasteboardType("com.bdwy.flux.menu-bar-icon")

    @Published private(set) var isMenuBarDragging = false
    @Published private(set) var message: String?
    var trace: ((String) -> Void)?

    private weak var manager: MenuBarIconManager?
    private weak var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var overlays: [NSPanel] = []
    private var overlayIcons: [MenuBarIconManager.Icon] = []
    private var returnPanels: [NSPanel] = []
    private var commandDown = false
    private var nativeGesture = false
    private var refreshing = false
    private var active: (token: String, icon: MenuBarIconManager.Icon, identity: MenuBarDragIdentity)?

    func open(manager: MenuBarIconManager, window: NSWindow) {
        guard settingsWindow !== window || self.manager !== manager else { return }
        close()
        self.manager = manager
        settingsWindow = window
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.willTerminateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopInput(reason: name.rawValue) }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopInput(reason: name.rawValue) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopInput(reason: "screen changed") }
        })
    }

    func close() {
        stopInput(reason: "management closed")
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        manager = nil
        settingsWindow = nil
    }

    func setMenuBarDragging(_ enabled: Bool) {
        stopInput(reason: "mode toggle \(enabled)")
        message = nil
        guard enabled else { return }
        guard canManage, AXIsProcessTrusted() else {
            message = "Keep Settings active and allow Accessibility to drag menu bar icons."
            return
        }
        let mask = [CGEventType.flagsChanged, .leftMouseDown, .leftMouseUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: mask,
                                             callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's source is attached only to the main run loop below.
            MainActor.assumeIsolated {
                let controller = Unmanaged<MenuBarDragController>.fromOpaque(context).takeUnretainedValue()
                controller.observe(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            message = "Menu bar dragging is unavailable. Use the row handles or Move menu."
            return
        }
        tap = newTap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: newTap) else {
            stopInput(reason: "tap not enabled")
            message = "Menu bar dragging is unavailable. Use the row handles or Move menu."
            return
        }
        commandDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        isMenuBarDragging = true
        refreshOverlays()
        let heartbeat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canManage else {
                    self.stopInput(reason: "heartbeat management inactive")
                    return
                }
                guard AXIsProcessTrusted() else {
                    self.stopInput(reason: "heartbeat grant lost")
                    return
                }
                guard let tap = self.tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
                    self.stopInput(reason: "heartbeat tap lost")
                    return
                }
                if self.active == nil && !self.nativeGesture && NSEvent.pressedMouseButtons & 1 == 0 {
                    self.refreshOverlays()
                }
            }
        }
        timer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
        trace?("mode enabled overlays=\(overlays.count) command=\(commandDown)")
    }

    func makeSourceView(for icon: MenuBarIconManager.Icon) -> MenuBarDragSourceView {
        let view = MenuBarDragSourceView(frame: .zero)
        view.controller = self
        view.icon = icon
        return view
    }

    func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard canManage, let active,
              sender.draggingSource as? MenuBarDragSourceView != nil,
              sender.draggingSourceOperationMask.contains(.move),
              sender.draggingPasteboard.string(forType: Self.pasteboardType) == active.token else { return false }
        return true
    }

    func performDrop(_ sender: NSDraggingInfo, to section: MenuBarSection) -> Bool {
        guard accepts(sender), let pending = active, let manager, AXIsProcessTrusted() else { return false }
        manager.refresh()
        let matches = manager.icons.filter { $0.id == pending.icon.id }
        guard matches.count == 1, let current = matches.first, current.isMovable,
              current.title == pending.icon.title, current.source == pending.icon.source,
              current.frame == pending.icon.frame,
              pending.identity.isCurrent(for: current) else {
            active = nil
            message = "That icon changed during the drag. Refresh icons and try again."
            trace?("drop rejected identity")
            return false
        }
        active = nil
        removeReturnPanels()
        setPassThrough(true)
        trace?("commit \(section.rawValue) \(current.id)")
        manager.move(current, to: section)
        return true
    }

    fileprivate func begin(icon: MenuBarIconManager.Icon, in view: MenuBarDragSourceView,
                           mouseDown: NSEvent) -> NSDraggingSession? {
        guard canManage, icon.isMovable, active == nil, let manager, AXIsProcessTrusted() else { return nil }
        manager.refresh()
        let matches = manager.icons.filter { $0.id == icon.id }
        guard matches.count == 1, let current = matches.first, current == icon,
              let identity = MenuBarDragIdentity(icon: current) else {
            message = "That icon changed. Refresh icons and try again."
            return nil
        }
        let token = UUID().uuidString
        active = (token, current, identity)
        let writer = NSPasteboardItem()
        writer.setString(token, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: current.title)!
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 28, height: 24), contents: image)
        setPassThrough(true)
        showReturnPanels()
        let session = view.beginDraggingSession(with: [item], event: mouseDown, source: view)
        session.animatesToStartingPositionsOnCancelOrFail = true
        trace?("begin window=\(mouseDown.windowNumber) source=\(view.window?.windowNumber ?? -1)")
        return session
    }

    fileprivate func ended(operation: NSDragOperation) {
        trace?("ended operation=\(operation.rawValue)")
        active = nil
        removeReturnPanels()
        // The manager can still be posting its native Command-drag after a drop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.isMenuBarDragging, self.active == nil else { return }
            self.refreshOverlays()
        }
    }

    private var canManage: Bool {
        guard let settingsWindow, let manager else { return false }
        return manager.isTrusted && NSApp.isActive && settingsWindow.isVisible
            && !settingsWindow.isMiniaturized && NSApp.keyWindow === settingsWindow
    }

    private func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            trace?("tap lost")
            stopInput(reason: "tap disabled event \(type.rawValue)")
            message = "Menu bar dragging stopped. Turn it on again to retry."
            return
        }
        commandDown = event.flags.contains(.maskCommand)
        if type == .leftMouseDown {
            nativeGesture = commandDown
            trace?("tap down command=\(commandDown)")
        }
        // Never replay, consume, or transplant a foreign mouse event. Set the
        // window input policy before returning the original Command-down.
        setPassThrough(commandDown || nativeGesture || active != nil)
        if type == .leftMouseUp { nativeGesture = false }
    }

    private func refreshOverlays() {
        guard !refreshing, isMenuBarDragging, canManage, let manager else { return }
        refreshing = true
        defer { refreshing = false }
        manager.refresh()
        guard manager.isTrusted else { stopInput(reason: "manager access lost"); return }
        let icons = manager.icons.filter { $0.isMovable }
        guard icons != overlayIcons else {
            setPassThrough(commandDown || nativeGesture || active != nil)
            return
        }
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays.removeAll()
        overlayIcons = icons
        for icon in icons {
            guard let frame = Self.appKitFrame(for: icon.frame),
                  NSScreen.screens.contains(where: { screen in
                      let strip = NSRect(x: screen.frame.minX, y: screen.frame.maxY - NSStatusBar.system.thickness - 16,
                                         width: screen.frame.width, height: NSStatusBar.system.thickness + 16)
                      return strip.contains(frame) && frame.width > 1
                  }) else { continue }
            let view = makeSourceView(for: icon)
            let panel = Self.panel(frame: frame, view: view)
            panel.ignoresMouseEvents = commandDown || nativeGesture || active != nil
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
    }

    private func setPassThrough(_ ignore: Bool) {
        for panel in overlays { panel.ignoresMouseEvents = ignore }
    }

    private func showReturnPanels() {
        trace?("return setup canManage=\(canManage) active=\(active != nil)")
        guard canManage, active != nil else { return }
        removeReturnPanels()
        for screen in NSScreen.screens {
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                               width: screen.frame.width, height: height)
            let view = MenuBarDragDestinationView(frame: .zero)
            view.controller = self
            view.section = .shown
            view.showsReturnHint = true
            let panel = Self.panel(frame: frame, view: view)
            panel.orderFrontRegardless()
            returnPanels.append(panel)
            trace?("return created window=\(panel.windowNumber) frame=\(panel.frame) visible=\(panel.isVisible) level=\(panel.level.rawValue)")
        }
    }

    private func removeReturnPanels() {
        returnPanels.forEach { $0.orderOut(nil); $0.close() }
        returnPanels.removeAll()
    }

    private func stopInput(reason: String) {
        let front = NSWorkspace.shared.frontmostApplication
        trace?("stop reason=\(reason) appActive=\(NSApp.isActive) key=\(NSApp.keyWindow?.windowNumber ?? -1) settings=\(settingsWindow?.windowNumber ?? -1) pid=\(ProcessInfo.processInfo.processIdentifier) front=\(front?.processIdentifier ?? -1):\(front?.bundleIdentifier ?? "nil")")
        active = nil
        isMenuBarDragging = false
        timer?.invalidate()
        timer = nil
        setPassThrough(true)
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays.removeAll()
        overlayIcons.removeAll()
        removeReturnPanels()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
        nativeGesture = false
        commandDown = false
        trace?("cleanup overlays=0 returns=0 tap=none")
    }

    private static func panel(frame: NSRect, view: NSView) -> NSPanel {
        let panel = MenuBarDragPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        return panel
    }

    private static func appKitFrame(for frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first, !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return nil }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
}

private final class MenuBarDragPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarDragSourceView: NSView, NSDraggingSource {
    weak var controller: MenuBarDragController?
    var icon: MenuBarIconManager.Icon?
    var showsHandle = false { didSet { needsDisplay = true } }
    private var down: NSEvent?
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

    override func mouseUp(with event: NSEvent) { down = nil }

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

    override func draw(_ dirtyRect: NSRect) {
        guard showsHandle else { return }
        NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag icon")?
            .draw(in: bounds.insetBy(dx: 3, dy: 5))
    }
}

@MainActor
final class MenuBarDragDestinationView: NSView {
    weak var controller: MenuBarDragController?
    var section: MenuBarSection = .shown
    var showsReturnHint = false
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([MenuBarDragController.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = controller?.accepts(sender) == true
        controller?.trace?("entered \(section.rawValue) valid=\(targeted)")
        return targeted ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = controller?.accepts(sender) == true
        return targeted ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.accepts(sender) == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        return controller?.performDrop(sender, to: section) == true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard targeted || showsReturnHint else { return }
        NSColor.controlAccentColor.withAlphaComponent(targeted ? 0.24 : 0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        if showsReturnHint {
            let text = "Drop to keep Shown" as NSString
            text.draw(at: NSPoint(x: 12, y: max(2, (bounds.height - 15) / 2)),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                       .foregroundColor: NSColor.labelColor])
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
        let parts = icon.id.split(separator: "|")
        let apps: [NSRunningApplication]
        let attribute: String
        if parts.count == 2, Int(parts[1]) != nil {
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: String(parts[0]))
            attribute = kAXExtrasMenuBarAttribute
        } else {
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver")
            attribute = kAXMenuBarAttribute
        }
        guard apps.count == 1, let owner = apps.first,
              let elements = Self.items(owner: owner, attribute: attribute) else { return nil }
        let matches = elements.enumerated().filter { Self.matches($0.element, icon: icon, owner: owner) }
        guard matches.count == 1, let match = matches.first else { return nil }
        if attribute == kAXExtrasMenuBarAttribute, match.offset != Int(parts[1]) { return nil }
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
              Self.matches(current[index], icon: icon, owner: owner) else { return false }
        return current.filter { Self.matches($0, icon: icon, owner: owner) }.count == 1
    }

    private static func items(owner: NSRunningApplication, attribute: String) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let value = read(app, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let bar = value as! AXUIElement
        return read(bar, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func matches(_ element: AXUIElement, icon: MenuBarIconManager.Icon,
                                owner: NSRunningApplication) -> Bool {
        let title = nonemptyString(element, kAXTitleAttribute)
            ?? nonemptyString(element, kAXDescriptionAttribute)
            ?? owner.localizedName ?? owner.bundleIdentifier
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
