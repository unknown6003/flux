import AppKit
import ApplicationServices
import Combine

/// Reads real menu-bar items and lets Settings assign their section and order.
@MainActor
final class MenuBarIconManager: ObservableObject {
    typealias Boundaries = (hidden: CGFloat?, alwaysHidden: CGFloat?)

    enum MoveDirection {
        case towardDrawer
        case towardClock
    }

    struct Icon: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String?
        let section: MenuBarSection
        let isMovable: Bool
        let frame: CGRect
    }

    @Published private(set) var icons: [Icon] = []
    @Published private(set) var isTrusted = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdatingIcons = false

    /// AppDelegate supplies the live boundaries after the status items exist.
    var boundaryProvider: () -> Boundaries = { (nil, nil) }
    var chevronBoundaryProvider: () -> CGFloat? = { nil }
    var alwaysHiddenEnabledProvider: () -> Bool = { true }
    var beginProvider: () -> Void = {}
    var endProvider: () -> Void = {}

    private var elements: [String: AXUIElement] = [:]
    private var assignedSections: [String: MenuBarSection] = [:]
    private struct NativeMove {
        let icon: Icon
        let element: AXUIElement
        let owner: NSRunningApplication
        let launched: Date?
        let start: CGPoint
        let frame: CGRect
        var dragged = false
    }
    private var nativeMove: NativeMove?
    private var completedNativeMove: NativeMove?
    private var nativeMoveGeneration = 0
    private var nativeMoveMonitor: Any?
    private var escapeMonitor: Any?
    private var iconUpdateCount = 0
    private let trustProvider: () -> Bool
    private lazy var macOS27Hider: MacOS27Hider = {
        let hider = MacOS27Hider()
        hider.onStatus = { [weak self] message in self?.errorMessage = message }
        hider.onReadState = { [weak self] reading in
            if reading { self?.beginIconUpdate() }
            else { self?.finishIconUpdate() }
        }
        return hider
    }()
    private var cancellables = Set<AnyCancellable>()

    var canHideWithoutAccess: Bool {
        ControlItem.usesMacOS27Model && macOS27Hider.isAvailable && macOS27Hider.hasSavedLayout
    }

    init(trustProvider: @escaping () -> Bool = { AccessibilityAccess.isGranted() }) {
        self.trustProvider = trustProvider
        observeAppActivation()
        observeNativeMoves()
    }

    deinit {
        if let nativeMoveMonitor { NSEvent.removeMonitor(nativeMoveMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    private func observeNativeMoves() {
        guard ControlItem.usesMacOS27Model else { return }
        nativeMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.observeNativeMove(event) }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown {
                    self?.commitNativeMove()
                    self?.nativeMoveGeneration += 1
                    self?.nativeMove = nil
                } else if event.keyCode == 53 { self?.nativeMove = nil }
            }
            return event
        }
    }

    private func observeNativeMove(_ event: NSEvent) {
        print("[DEBUG-native-save] t=\(ProcessInfo.processInfo.systemUptime) event=\(event.type.rawValue) flags=\(event.modifierFlags.rawValue) source=\(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1) own=\(getpid()) point=\(String(describing: event.cgEvent?.location))")
        if event.type == .keyDown {
            if event.keyCode == 53 { nativeMove = nil }
            return
        }
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        switch event.type {
        case .leftMouseDown:
            commitNativeMove()
            nativeMoveGeneration += 1
            nativeMove = nil
            guard event.modifierFlags.contains(.command),
                  let primary = NSScreen.screens.first else { return }
            let point = cgEvent.location
            let appKitPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
            guard NSScreen.screens.contains(where: {
                $0.frame.contains(appKitPoint)
                    && appKitPoint.y >= $0.frame.maxY - max(NSStatusBar.system.thickness, $0.safeAreaInsets.top)
            }) else { return }
            beginIconUpdate()
            defer { finishIconUpdate() }
            refresh()
            let matches = icons.filter { $0.isMovable && $0.frame.contains(point) }
            print("[DEBUG-native-save] down trusted=\(isTrusted) matches=\(matches.map(\.title))")
            guard isTrusted, matches.count == 1, let icon = matches.first,
                  let element = elements[icon.id] else { return }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                  let owner = NSRunningApplication(processIdentifier: pid),
                  let bundleID = owner.bundleIdentifier, icon.id.hasPrefix(bundleID + "|"),
                  macOS27Hider.canReadPosition(for: bundleID),
                  let frame = frame(of: element), frame.contains(point) else { return }
            nativeMove = NativeMove(icon: icon, element: element, owner: owner,
                                    launched: owner.launchDate, start: point, frame: frame)
            print("[DEBUG-native-save] captured \(icon.title)")
        case .leftMouseDragged:
            guard let pending = nativeMove else { return }
            if hypot(cgEvent.location.x - pending.start.x, cgEvent.location.y - pending.start.y) >= 3 {
                nativeMove?.dragged = true
            }
        case .leftMouseUp:
            let pending = nativeMove
            nativeMove = nil
            guard let pending, pending.dragged else { return }
            print("[DEBUG-native-save] completed \(pending.icon.title)")
            completedNativeMove = pending
            let generation = nativeMoveGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.nativeMoveGeneration == generation,
                      self.nativeMove == nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.commitNativeMove()
            }
        default: break
        }
    }

    private func commitNativeMove() {
        print("[DEBUG-native-save] t=\(ProcessInfo.processInfo.systemUptime) commit pending=\(completedNativeMove?.icon.title ?? "none")")
        guard let pending = completedNativeMove else { return }
        completedNativeMove = nil
        guard !pending.owner.isTerminated,
              pending.owner.launchDate == pending.launched else { return }
        beginIconUpdate()
        defer { finishIconUpdate() }
        refresh()
        let matches = icons.filter {
            elements[$0.id].map { CFEqual($0, pending.element) } ?? false
        }
        print("[DEBUG-native-save] verify trusted=\(isTrusted) matches=\(matches.map(\.title)) readable=\(macOS27Hider.canReadPosition(for: pending.owner.bundleIdentifier ?? "")) oldX=\(pending.frame.midX) new=\(matches.map { $0.frame.midX })")
        guard isTrusted, matches.count == 1, let current = matches.first,
              current.title == pending.icon.title, current.source == pending.icon.source,
              let bundleID = pending.owner.bundleIdentifier,
              macOS27Hider.canReadPosition(for: bundleID),
              abs(current.frame.midX - pending.frame.midX) >= 3 else { return }
        if saveLayout(for: current) {
            assignedSections.removeValue(forKey: current.id)
            refresh()
        } else {
            errorMessage = "Flux could not save that icon's new position. Try again."
        }
    }

    private func observeAppActivation() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.beginIconUpdate()
                defer { self.finishIconUpdate() }
                _ = AccessibilityAccess.isGranted(forceRefresh: true)
                self.refresh()
                if ControlItem.usesMacOS27Model { self.macOS27Hider.retry() }
            }
            .store(in: &cancellables)
    }

    /// Opens the system pane without asking macOS to show a TCC prompt.
    /// Repeated prompts are especially bad here because a stale TCC entry can
    /// make the same request appear on every Settings visit.
    func requestAccess() {
        guard !trustProvider() else {
            refresh()
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func beginIconManagement() {
        guard !ControlItem.usesMacOS27Model || trustProvider() else {
            refresh()
            return
        }
        beginProvider()
        refresh()
        applyDrawerVisibility(revealHidden: true,
                              revealAlwaysHidden: true,
                              refreshBeforeApplying: false)
        refreshAfterLayout(settles: true)
    }

    func endIconManagement() {
        if nativeMove == nil { commitNativeMove() }
        endProvider()
    }

    func copyMenuBarReport() {
        beginIconUpdate()
        defer { finishIconUpdate() }
        let report = ControlItem.usesMacOS27Model ? macOS27Hider.diagnostics
            : "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(trustProvider())\nThe macOS 27 hiding path is not active."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func refresh() {
        beginIconUpdate()
        defer { finishIconUpdate() }
        isTrusted = trustProvider()
        guard isTrusted else {
            icons = []
            elements.removeAll()
            errorMessage = "Allow Accessibility access to manage menu-bar icons."
            return
        }

        if ControlItem.usesMacOS27Model {
            refreshMacOS27()
            return
        }

        guard let systemUI = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systemuiserver").first
            ?? NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == "SystemUIServer"
            }) else {
            icons = []
            errorMessage = "Flux could not find the macOS menu bar."
            return
        }

        let app = AXUIElementCreateApplication(systemUI.processIdentifier)
        guard let menuBar = elementAttribute(app, kAXMenuBarAttribute) else {
            icons = []
            errorMessage = "Flux could not read the macOS menu bar."
            return
        }

        let boundaries = boundaryProvider()
        var next: [Icon] = []
        var nextElements: [String: AXUIElement] = [:]
        for (index, element) in children(of: menuBar).enumerated() {
            guard stringAttribute(element, kAXRoleAttribute) == (kAXMenuBarItemRole as String),
                  let frame = frame(of: element) else { continue }

            let identifier = stringAttribute(element, kAXIdentifierAttribute)
            let title = stringAttribute(element, kAXTitleAttribute)
                ?? stringAttribute(element, kAXDescriptionAttribute)
                ?? "Menu bar item \(index + 1)"
            let source = stringAttribute(element, kAXHelpAttribute)
            let id = identifier ?? "\(title)|\(source ?? "")|\(index)"
            guard !isFluxItem(identifier: identifier, title: title, source: source) else { continue }

            let section = assignedSections[id]
                ?? Self.section(for: frame, boundaries: boundaries)
            next.append(Icon(id: id,
                             title: title,
                             source: source,
                             section: section,
                             isMovable: true,
                             frame: frame))
            nextElements[id] = element
        }

        icons = next.sorted { $0.frame.minX < $1.frame.minX }
        elements = nextElements
        errorMessage = nil
    }

    /// MenuBarAgent owns the drawn bar on macOS 27, but each app exposes its
    /// own status items through AXExtrasMenuBar.
    private func refreshMacOS27() {
        let boundaries = boundaryProvider()
        var next: [Icon] = []
        var nextElements: [String: AXUIElement] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  !bundleID.hasPrefix("com.apple."),
                  app.activationPolicy != .prohibited,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            let owner = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(owner, 0.2)
            guard let bar = elementAttribute(owner, kAXExtrasMenuBarAttribute) else { continue }
            for (index, element) in children(of: bar).enumerated() {
                guard let frame = frame(of: element) else { continue }
                let title = stringAttribute(element, kAXTitleAttribute)
                    ?? stringAttribute(element, kAXDescriptionAttribute)
                    ?? app.localizedName ?? bundleID
                let id = "\(bundleID)|\(index)"
                let section = assignedSections[id]
                    ?? macOS27Hider.section(for: bundleID)
                    ?? Self.section(for: frame, boundaries: boundaries)
                next.append(Icon(id: id, title: title, source: app.localizedName,
                                 section: section, isMovable: true, frame: frame))
                nextElements[id] = element
            }
        }
        next.append(contentsOf: liveActivityIcons())
        icons = next.sorted { $0.frame.minX < $1.frame.minX }
        elements = nextElements
        errorMessage = macOS27Hider.isAvailable ? macOS27Hider.latestError
            : "Hiding is unavailable on this macOS build. Flux needs an update."
    }

    private func liveActivityIcons() -> [Icon] {
        guard let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
        let owner = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.15)
        guard let bar = elementAttribute(owner, kAXExtrasMenuBarAttribute) else { return [] }
        var result: [Icon] = []
        var visited = 0
        @MainActor func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 6, visited < 100 else { return }
            visited += 1
            if let identifier = stringAttribute(element, kAXIdentifierAttribute),
               identifier.hasPrefix("live-activity-pill-"), let frame = frame(of: element) {
                let label = activityImageLabel(in: element)
                result.append(Icon(id: "system-activity|\(identifier)",
                                   title: label ?? "Live Activity",
                                   source: "Live Activity managed by macOS",
                                   section: .shown, isMovable: false, frame: frame))
                return
            }
            for child in children(of: element) { visit(child, depth: depth + 1) }
        }
        visit(bar, depth: 0)
        return result
    }

    private func activityImageLabel(in element: AXUIElement) -> String? {
        var visited = 0
        @MainActor func label(_ item: AXUIElement, depth: Int) -> String? {
            guard depth < 5, visited < 40 else { return nil }
            visited += 1
            if stringAttribute(item, kAXRoleAttribute) == kAXImageRole as String,
               let text = stringAttribute(item, kAXDescriptionAttribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            for child in children(of: item) {
                if let text = label(child, depth: depth + 1) { return text }
            }
            return nil
        }
        return label(element, depth: 0)
    }

    func move(_ icon: Icon, to section: MenuBarSection) {
        guard icon.isMovable,
              let targetX = Self.insertionX(for: section,
                                             iconWidth: icon.frame.width,
                                             boundaries: boundaryProvider()) else {
            return
        }
        assignedSections[icon.id] = section
        move(icon, toX: targetX, expectedSection: section)
    }

    func canMove(_ icon: Icon, toward direction: MoveDirection) -> Bool {
        guard icon.isMovable else { return false }
        let siblings = icons
            .filter { $0.section == icon.section }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = siblings.firstIndex(where: { $0.id == icon.id }) else { return false }
        switch direction {
        case .towardDrawer:
            return index > siblings.startIndex
        case .towardClock:
            return index < siblings.index(before: siblings.endIndex)
        }
    }

    /// Moves an icon one place within its current section. The drawer UI owns
    /// order, so the user never has to Cmd-drag a crowded menu bar.
    func move(_ icon: Icon, toward direction: MoveDirection) {
        guard canMove(icon, toward: direction) else { return }
        let siblings = icons
            .filter { $0.section == icon.section }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = siblings.firstIndex(where: { $0.id == icon.id }) else { return }
        let neighbor: Icon
        switch direction {
        case .towardDrawer:
            neighbor = siblings[siblings.index(before: index)]
            move(icon, toX: neighbor.frame.minX - icon.frame.width - 4, expectedSection: icon.section)
        case .towardClock:
            neighbor = siblings[siblings.index(after: index)]
            move(icon, toX: neighbor.frame.maxX + 4, expectedSection: icon.section)
        }
    }

    // Kept for callers from older settings views during an update.
    func setSection(_ section: MenuBarSection, for icon: Icon) {
        move(icon, to: section)
    }

    /// Applies the drawer's visibility. macOS 27 needs MenuBarAgent's app-level
    /// restriction; older systems keep the divider geometry.
    func applyDrawerVisibility(revealHidden: Bool,
                               revealAlwaysHidden: Bool,
                               refreshBeforeApplying: Bool = true) {
        beginIconUpdate()
        defer { finishIconUpdate() }
        if ControlItem.usesMacOS27Model {
            if nativeMove == nil { commitNativeMove() }
            macOS27Hider.apply(revealHidden: revealHidden,
                               revealAlwaysHidden: revealAlwaysHidden,
                               alwaysHiddenEnabled: alwaysHiddenEnabledProvider(),
                               chevronX: { [weak self] in self?.chevronBoundaryProvider() },
                               alwaysX: { [weak self] in self?.boundaryProvider().alwaysHidden })
            return
        }
        if refreshBeforeApplying, icons.isEmpty { refresh() }
        for icon in icons {
            guard let element = elements[icon.id] else { continue }
            let visible = Self.isVisible(icon.section,
                                         revealHidden: revealHidden,
                                         revealAlwaysHidden: revealAlwaysHidden)
            setHidden(!visible, on: element)
        }
    }

    static func isVisible(_ section: MenuBarSection,
                          revealHidden: Bool,
                          revealAlwaysHidden: Bool) -> Bool {
        switch section {
        case .shown: return true
        case .hidden: return revealHidden
        case .alwaysHidden: return revealAlwaysHidden
        }
    }

    static func section(for frame: CGRect, boundaries: Boundaries) -> MenuBarSection {
        if let alwaysHidden = boundaries.alwaysHidden, frame.midX < alwaysHidden {
            return .alwaysHidden
        }
        if let hidden = boundaries.hidden, frame.midX < hidden {
            return .hidden
        }
        return .shown
    }

    static func insertionX(for section: MenuBarSection,
                           iconWidth: CGFloat,
                           boundaries: Boundaries,
                           gap: CGFloat = 12) -> CGFloat? {
        switch section {
        case .shown:
            return boundaries.hidden.map { $0 + gap }
        case .hidden:
            if let alwaysHidden = boundaries.alwaysHidden, let hidden = boundaries.hidden {
                guard alwaysHidden < hidden else { return nil }
                // The drag uses the icon's center. Keep that center between the
                // boundaries even when macOS 27 leaves only a few points there.
                return (alwaysHidden + hidden - iconWidth) / 2
            }
            return boundaries.hidden.map { $0 - iconWidth - gap }
        case .alwaysHidden:
            return boundaries.alwaysHidden.map { $0 - iconWidth - gap }
        }
    }

    private func move(_ icon: Icon, toX targetX: CGFloat, expectedSection: MenuBarSection) {
        beginIconUpdate()
        if nativeMove == nil { commitNativeMove() }
        guard let element = elements[icon.id] else {
            refresh()
            finishIconUpdate()
            return
        }

        let target = CGPoint(x: targetX, y: icon.frame.minY)
        let usedAccessibility = setPosition(target, on: element)
        if !usedAccessibility {
            drag(icon.frame, to: CGPoint(x: targetX + icon.frame.width / 2,
                                          y: icon.frame.midY))
        }
        verifyMove(icon: icon,
                   expectedSection: expectedSection,
                   target: target,
                   retryWithDrag: usedAccessibility)
    }

    private func beginIconUpdate() {
        iconUpdateCount += 1
        if iconUpdateCount == 1 { isUpdatingIcons = true }
    }

    private func finishIconUpdate() {
        iconUpdateCount -= 1
        if iconUpdateCount == 0 { isUpdatingIcons = false }
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func setHidden(_ hidden: Bool, on element: AXUIElement) {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element,
                                              kAXHiddenAttribute as CFString,
                                              &settable) == .success,
              settable.boolValue else { return }
        _ = AXUIElementSetAttributeValue(element,
                                          kAXHiddenAttribute as CFString,
                                          NSNumber(value: hidden))
    }

    private func verifyMove(icon: Icon,
                            expectedSection: MenuBarSection,
                            target: CGPoint,
                            retryWithDrag: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.refresh()
            guard let current = self.icons.first(where: { $0.id == icon.id }) else {
                self.finishIconUpdate()
                return
            }
            let actualSection = Self.section(for: current.frame,
                                             boundaries: self.boundaryProvider())
            guard actualSection != expectedSection else {
                if !self.saveLayout(for: current) {
                    self.assignedSections.removeValue(forKey: current.id)
                    self.refresh()
                    self.errorMessage = "Flux moved the icon but could not save its section. Try again."
                }
                self.finishIconUpdate()
                return
            }
            guard retryWithDrag else {
                self.assignedSections.removeValue(forKey: icon.id)
                self.refresh()
                self.errorMessage = "macOS did not move \(icon.title). Try again."
                self.finishIconUpdate()
                return
            }
            self.drag(icon.frame, to: CGPoint(x: target.x + icon.frame.width / 2,
                                               y: icon.frame.midY))
            self.verifyMove(icon: icon,
                            expectedSection: expectedSection,
                            target: target,
                            retryWithDrag: false)
        }
    }

    private func saveLayout(for icon: Icon) -> Bool {
        guard ControlItem.usesMacOS27Model else { return true }
        guard let bundleID = icon.id.split(separator: "|", maxSplits: 1).first else { return false }
        return macOS27Hider.recordLayoutChange(for: String(bundleID))
    }

    private func refreshAfterLayout(settles: Bool) {
        let delays: [TimeInterval] = settles ? [0.15, 0.5] : [0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func drag(_ frame: CGRect, to target: CGPoint) {
        let start = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(mouseEventSource: nil,
                                 mouseType: .leftMouseDown,
                                 mouseCursorPosition: start,
                                 mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: target,
                               mouseButton: .left) else { return }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        for step in 1...5 {
            let progress = CGFloat(step) / 5
            let point = CGPoint(x: start.x + (target.x - start.x) * progress,
                                y: start.y + (target.y - start.y) * progress)
            guard let move = CGEvent(mouseEventSource: nil,
                                     mouseType: .leftMouseDragged,
                                     mouseCursorPosition: point,
                                     mouseButton: .left) else { continue }
            move.flags = .maskCommand
            move.post(tap: .cghidEventTap)
        }
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }

    private func isFluxItem(identifier: String?, title: String, source: String?) -> Bool {
        [identifier, source, title].compactMap { $0?.lowercased() }
            .contains { $0 == "flux" || $0.contains("flux.") }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        guard let text = (attribute(element, key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
