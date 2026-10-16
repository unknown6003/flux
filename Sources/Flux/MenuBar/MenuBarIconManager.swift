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
        var identity: UUID? = nil
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
        let section: MenuBarSection
        var dragged = false
        var saveAttempts = 0
    }
    private var nativeMove: NativeMove?
    private var completedNativeMoves: [UUID: NativeMove] = [:]
    private var nativeMoveGeneration = 0
    private var nativeInputGeneration = 0
    private var nativeMoveMonitor: Any?
    private var escapeMonitor: Any?
    private var iconUpdateCount = 0
    private var iconManagementGeneration = 0
    private var pendingMoveCount = 0
    private var deferredVisibility: (hidden: Bool, alwaysHidden: Bool, refresh: Bool)?
    private var nativeSaveFailures = Set<String>()
    private var lastMoveReport = "none"
    private var lastMoveVerification = "none"
    private var nativeSaveError: String? {
        nativeSaveFailures.isEmpty ? nil : "Flux could not save an icon's new position. Try again."
    }
    private let trustProvider: () -> Bool
    private let injectedHider: MacOS27Hider?
    private lazy var macOS27Hider: MacOS27Hider = {
        let hider = injectedHider ?? MacOS27Hider()
        hider.onStatus = { [weak self] message in
            guard let self else { return }
            self.updateErrorMessage(self.nativeSaveError ?? message)
        }
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

    init(trustProvider: @escaping () -> Bool = { AccessibilityAccess.isGranted() },
         hider: MacOS27Hider? = nil) {
        self.trustProvider = trustProvider
        injectedHider = hider
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
                    self?.nativeInputGeneration += 1
                    self?.nativeMove = nil
                    self?.scheduleNativeMoveCommit()
                } else if event.keyCode == 53 {
                    self?.nativeMove = nil
                    self?.scheduleNativeMoveCommit()
                }
            }
            return event
        }
    }

    private func observeNativeMove(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 {
                nativeMove = nil
                scheduleNativeMoveCommit()
            }
            return
        }
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        switch event.type {
        case .leftMouseDown:
            nativeInputGeneration += 1
            nativeMove = nil
            scheduleNativeMoveCommit()
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
                                    launched: owner.launchDate, start: point, frame: frame,
                                    section: Self.section(for: frame, boundaries: boundaryProvider()))
        case .leftMouseDragged:
            guard let pending = nativeMove else { return }
            if hypot(cgEvent.location.x - pending.start.x, cgEvent.location.y - pending.start.y) >= 3 {
                nativeMove?.dragged = true
            }
        case .leftMouseUp:
            let pending = nativeMove
            nativeMove = nil
            if let pending, pending.dragged,
               !completedNativeMoves.values.contains(where: {
                   !$0.owner.isTerminated && CFEqual($0.element, pending.element)
               }) {
                completedNativeMoves[UUID()] = pending
            }
            scheduleNativeMoveCommit()
        default: break
        }
    }

    private func scheduleNativeMoveCommit() {
        nativeMoveGeneration += 1
        let generation = nativeMoveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.nativeMoveGeneration == generation else { return }
            self.commitNativeMoves()
        }
    }

    private func commitNativeMoves() {
        guard nativeInputIsQuiet(), pendingMoveCount == 0 else {
            scheduleNativeMoveCommit()
            return
        }
        nativeMove = nil
        guard !completedNativeMoves.isEmpty else {
            applyDeferredVisibility()
            return
        }
        let downCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        let generation = nativeMoveGeneration
        let canCommit = {
            self.nativeMoveGeneration == generation
                && !CGEventSource.buttonState(.combinedSessionState, button: .left)
                && CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downCount
        }
        beginIconUpdate()
        defer { finishIconUpdate() }
        refresh()
        var changes: [String: Icon] = [:]
        var changedMoves: [UUID] = []
        for (key, pending) in completedNativeMoves {
            guard canCommit() else { scheduleNativeMoveCommit(); return }
            let matches = icons.filter {
                elements[$0.id].map { CFEqual($0, pending.element) } ?? false
            }
            guard !pending.owner.isTerminated, pending.owner.launchDate == pending.launched,
                  let bundleID = pending.owner.bundleIdentifier else {
                completedNativeMoves.removeValue(forKey: key)
                continue
            }
            guard isTrusted, !matches.isEmpty else {
                retryNativeSave(pending, key: key)
                continue
            }
            guard matches.count == 1, let current = matches.first,
                  current.title == pending.icon.title, current.source == pending.icon.source,
                  current.isMovable else {
                completedNativeMoves.removeValue(forKey: key)
                nativeSaveFailures.insert(bundleID)
                continue
            }
            guard macOS27Hider.canReadPosition(for: bundleID) else {
                scheduleNativeMoveCommit()
                return
            }
            guard abs(current.frame.midX - pending.frame.midX) >= 3
                    || Self.section(for: current.frame, boundaries: boundaryProvider()) != pending.section else {
                completedNativeMoves.removeValue(forKey: key)
                continue
            }
            changes[bundleID] = current
            changedMoves.append(key)
        }
        if !changes.isEmpty {
            let saved = macOS27Hider.recordAvailableLayoutChanges(for: Set(changes.keys), canCommit: canCommit)
            guard canCommit() else { scheduleNativeMoveCommit(); return }
            nativeSaveFailures.subtract(saved)
            assignedSections = assignedSections.filter { entry in
                !saved.contains(where: { entry.key.hasPrefix($0 + "|") })
            }
            for key in changedMoves {
                guard let pending = completedNativeMoves[key],
                      let bundleID = pending.owner.bundleIdentifier else { continue }
                if saved.contains(bundleID) {
                    completedNativeMoves.removeValue(forKey: key)
                } else {
                    retryNativeSave(pending, key: key)
                }
            }
        }
        refresh()
        if !completedNativeMoves.isEmpty { scheduleNativeMoveCommit() }
        applyDeferredVisibility()
    }

    private func retryNativeSave(_ move: NativeMove, key: UUID) {
        var move = move
        move.saveAttempts += 1
        if move.saveAttempts < 3 {
            completedNativeMoves[key] = move
        } else {
            completedNativeMoves.removeValue(forKey: key)
            if let bundleID = move.owner.bundleIdentifier { nativeSaveFailures.insert(bundleID) }
        }
    }

    private func nativeInputIsQuiet() -> Bool {
        !CGEventSource.buttonState(.combinedSessionState, button: .left)
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) >= 0.35
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) >= 0.35
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
        iconManagementGeneration += 1
        guard !ControlItem.usesMacOS27Model || trustProvider() else {
            refresh()
            return
        }
        beginProvider()
        refresh()
        applyDrawerVisibility(revealHidden: true,
                              revealAlwaysHidden: true,
                              refreshBeforeApplying: false)
        let generation = iconManagementGeneration
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.iconManagementGeneration == generation else { return }
                self.refresh()
            }
        }
    }

    func endIconManagement() {
        iconManagementGeneration += 1
        endProvider()
    }

    func copyMenuBarReport() {
        beginIconUpdate()
        defer { finishIconUpdate() }
        let report = ControlItem.usesMacOS27Model ? macOS27Hider.diagnostics
            : "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(trustProvider())\nThe macOS 27 hiding path is not active."
        let boundaries = boundaryProvider()
        let moveReport = """

        Move boundaries: hidden=\(String(describing: boundaries.hidden)), always=\(String(describing: boundaries.alwaysHidden))
        Event posting allowed: \(CGPreflightPostEventAccess())
        Last move request: \(lastMoveReport)
        Last move verification: \(lastMoveVerification)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report + moveReport, forType: .string)
    }

    func refresh() {
        beginIconUpdate()
        defer { finishIconUpdate() }
        let trusted = trustProvider()
        if isTrusted != trusted { isTrusted = trusted }
        guard isTrusted else {
            updateInventory([])
            elements.removeAll()
            updateErrorMessage("Allow Accessibility access to manage menu-bar icons.")
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
            updateInventory([])
            updateErrorMessage("Flux could not find the macOS menu bar.")
            return
        }

        let app = AXUIElementCreateApplication(systemUI.processIdentifier)
        guard let menuBar = elementAttribute(app, kAXMenuBarAttribute) else {
            updateInventory([])
            updateErrorMessage("Flux could not read the macOS menu bar.")
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
                             frame: frame,
                             identity: identity(for: id, element: element)))
            nextElements[id] = element
        }

        updateInventory(next.sorted { $0.frame.minX < $1.frame.minX })
        elements = nextElements
        updateErrorMessage(nil)
    }

    private func updateInventory(_ next: [Icon]) {
        if icons != next { icons = next }
    }

    private func updateErrorMessage(_ message: String?) {
        if errorMessage != message { errorMessage = message }
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
            let items = children(of: bar)
            for (index, element) in items.enumerated() {
                guard let frame = frame(of: element) else { continue }
                let title = stringAttribute(element, kAXTitleAttribute)
                    ?? stringAttribute(element, kAXDescriptionAttribute)
                    ?? app.localizedName ?? bundleID
                let id = "\(bundleID)|\(index)"
                let section = assignedSections[id]
                    ?? macOS27Hider.section(for: bundleID)
                    ?? Self.section(for: frame, boundaries: boundaries)
                next.append(Icon(id: id, title: title, source: app.localizedName,
                                 section: section, isMovable: true, frame: frame,
                                 identity: identity(for: id, element: element, ownerItemCount: items.count)))
                nextElements[id] = element
            }
        }
        next.append(contentsOf: liveActivityIcons())
        updateInventory(next.sorted { $0.frame.minX < $1.frame.minX })
        elements = nextElements
        updateErrorMessage(nativeSaveError ?? (macOS27Hider.isAvailable ? macOS27Hider.latestError
            : "Hiding is unavailable on this macOS build. Flux needs an update."))
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

    private func identity(for id: String, element: AXUIElement, ownerItemCount: Int? = nil) -> UUID {
        let owner = id.split(separator: "|", maxSplits: 1).first.map(String.init)
        let sameCount = ownerItemCount.map { count in
            icons.filter { $0.isMovable && $0.id.hasPrefix((owner ?? id) + "|") }.count == count
        } ?? true
        // macOS can reuse the same remote AX object when another item takes its index.
        if sameCount, let previous = elements[id], CFEqual(previous, element),
           let identity = icons.first(where: { $0.id == id })?.identity {
            return identity
        }
        return UUID()
    }

    private func refreshedIcon(_ icon: Icon) -> Icon? {
        guard icon.isMovable else { return nil }
        refresh()
        guard let current = icons.first(where: { $0.id == icon.id && $0.isMovable }) else {
            if isTrusted { errorMessage = "Flux could not find this icon. Refresh icons and try again." }
            return nil
        }
        guard current.title == icon.title, current.source == icon.source,
              icon.identity == nil || current.identity == icon.identity else {
            errorMessage = "This icon changed. Refresh icons and try again."
            return nil
        }
        if ControlItem.usesMacOS27Model {
            guard current.frame.width > 0, current.frame.height > 0,
                  let primary = NSScreen.screens.first,
                  NSScreen.screens.contains(where: {
                      $0.statusItemRegion.contains(NSPoint(x: current.frame.midX,
                                                          y: primary.frame.maxY - current.frame.midY))
                  }) else {
                errorMessage = "Flux could not read this icon's current position. Refresh icons and try again."
                return nil
            }
        }
        return current
    }

    func move(_ icon: Icon, to section: MenuBarSection) {
        if deferMoveUntilMenuCloses({ [weak self] in self?.move(icon, to: section) }) { return }
        guard let icon = refreshedIcon(icon),
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
        if deferMoveUntilMenuCloses({ [weak self] in self?.move(icon, toward: direction) }) { return }
        guard let icon = refreshedIcon(icon), canMove(icon, toward: direction) else { return }
        let siblings = icons
            .filter { $0.section == icon.section }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let index = siblings.firstIndex(where: { $0.id == icon.id }) else { return }
        let neighbor: Icon
        var targetX: CGFloat
        switch direction {
        case .towardDrawer:
            neighbor = siblings[siblings.index(before: index)]
            targetX = neighbor.frame.minX - icon.frame.width - 4
        case .towardClock:
            neighbor = siblings[siblings.index(after: index)]
            targetX = neighbor.frame.maxX + 4
        }
        let bounds = boundaryProvider()
        if ControlItem.usesMacOS27Model {
            targetX = neighbor.frame.midX - icon.frame.width / 2
                + (direction == .towardClock ? 4 : -4)
            guard Self.section(for: CGRect(x: targetX, y: icon.frame.minY,
                                          width: icon.frame.width, height: icon.frame.height),
                               boundaries: bounds) == icon.section else {
                errorMessage = "Flux could not read this icon's current section. Refresh icons and try again."
                return
            }
        }
        move(icon, toX: targetX, expectedSection: icon.section, allowNativeRetry: false)
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
        if ControlItem.usesMacOS27Model,
           pendingMoveCount > 0 || nativeMove != nil || !completedNativeMoves.isEmpty
            || CGEventSource.buttonState(.combinedSessionState, button: .left) {
            deferredVisibility = (revealHidden, revealAlwaysHidden, refreshBeforeApplying)
            scheduleNativeMoveCommit()
            return
        }
        beginIconUpdate()
        defer { finishIconUpdate() }
        if ControlItem.usesMacOS27Model {
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

    private func visibleMenuWindow() -> Bool? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid())
                && ($0[kCGWindowLayer as String] as? Int) == NSWindow.Level.popUpMenu.rawValue
        }
    }

    private func deferMoveUntilMenuCloses(_ action: @escaping () -> Void) -> Bool {
        guard ControlItem.usesMacOS27Model else { return false }
        guard let visible = visibleMenuWindow() else {
            errorMessage = "Flux could not read the menu state. Try again."
            return true
        }
        guard visible else { return false }
        beginIconUpdate()
        pendingMoveCount += 1
        lastMoveReport = "waiting for menu to close"
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let wasActive = NSApp.isActive
        let downCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        func cancel(_ message: String) {
            finishMove()
            errorMessage = message
            lastMoveVerification = message
        }
        func poll() {
            guard (!wasActive || NSApp.isActive),
                  CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downCount else {
                cancel("Icon move cancelled because input changed. Try again.")
                return
            }
            guard let visible = visibleMenuWindow() else {
                cancel("Flux could not read the menu state. Try again.")
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                cancel("Close the menu, then try moving the icon again.")
                return
            }
            if !visible {
                action()
                finishMove()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        DispatchQueue.main.async { poll() }
        return true
    }

    private func move(_ icon: Icon, toX targetX: CGFloat, expectedSection: MenuBarSection,
                      allowNativeRetry: Bool = true) {
        let inputGeneration = nativeInputGeneration
        beginIconUpdate()
        pendingMoveCount += 1
        if let bundleID = icon.id.split(separator: "|", maxSplits: 1).first {
            completedNativeMoves = completedNativeMoves.filter { $0.value.owner.bundleIdentifier != String(bundleID) }
        }
        guard let element = elements[icon.id] else {
            refresh()
            finishMove()
            return
        }

        let target = CGPoint(x: targetX, y: icon.frame.minY)
        lastMoveReport = "id=\(icon.id), source=\(icon.frame), target=\(CGPoint(x: targetX + icon.frame.width / 2, y: icon.frame.midY)), expected=\(expectedSection.rawValue), mode=\(RunLoop.current.currentMode?.rawValue ?? "none")"
        lastMoveVerification = "pending"
        let usedAccessibility = !ControlItem.usesMacOS27Model && setPosition(target, on: element)
        if !usedAccessibility {
            drag(icon.frame, to: CGPoint(x: targetX + icon.frame.width / 2,
                                          y: icon.frame.midY))
        }
        verifyMove(icon: icon,
                   expectedSection: expectedSection,
                   target: target,
                   retryWithDrag: usedAccessibility || (ControlItem.usesMacOS27Model && allowNativeRetry),
                   inputGeneration: inputGeneration)
    }

    private func beginIconUpdate() {
        iconUpdateCount += 1
        if iconUpdateCount == 1 { isUpdatingIcons = true }
    }

    private func finishIconUpdate() {
        iconUpdateCount -= 1
        if iconUpdateCount == 0 { isUpdatingIcons = false }
    }

    private func finishMove() {
        pendingMoveCount -= 1
        applyDeferredVisibility()
        finishIconUpdate()
    }

    private func applyDeferredVisibility() {
        if pendingMoveCount == 0, nativeMove == nil, completedNativeMoves.isEmpty,
           let visibility = deferredVisibility {
            deferredVisibility = nil
            applyDrawerVisibility(revealHidden: visibility.hidden,
                                  revealAlwaysHidden: visibility.alwaysHidden,
                                  refreshBeforeApplying: visibility.refresh)
        }
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
                            retryWithDrag: Bool,
                            readAttempts: Int = 0,
                            inputGeneration: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            guard !ControlItem.usesMacOS27Model || self.nativeInputIsQuiet() else {
                self.verifyMove(icon: icon, expectedSection: expectedSection,
                                target: target, retryWithDrag: retryWithDrag,
                                readAttempts: readAttempts, inputGeneration: inputGeneration)
                return
            }
            let downCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
            let canCommit = {
                !ControlItem.usesMacOS27Model || (
                    self.nativeInputIsQuiet()
                    && CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downCount)
            }
            self.refresh()
            guard canCommit() else {
                self.verifyMove(icon: icon, expectedSection: expectedSection,
                                target: target, retryWithDrag: retryWithDrag,
                                readAttempts: readAttempts, inputGeneration: inputGeneration)
                return
            }
            guard let current = self.icons.first(where: { $0.id == icon.id }) else {
                self.lastMoveVerification = "id=\(icon.id), inventory unavailable, attempt=\(readAttempts + 1)"
                if readAttempts < 2 {
                    self.verifyMove(icon: icon, expectedSection: expectedSection,
                                    target: target, retryWithDrag: retryWithDrag,
                                    readAttempts: readAttempts + 1, inputGeneration: inputGeneration)
                    return
                }
                self.finishUnsavedMove(icon)
                return
            }
            let actualSection = Self.section(for: current.frame,
                                             boundaries: self.boundaryProvider())
            self.lastMoveVerification = "id=\(current.id), frame=\(current.frame), actual=\(actualSection.rawValue), expected=\(expectedSection.rawValue), boundaries=\(self.boundaryProvider())"
            guard actualSection != expectedSection else {
                if !self.saveLayout(for: current, canCommit: canCommit) {
                    guard canCommit() else {
                        self.verifyMove(icon: icon, expectedSection: expectedSection,
                                        target: target, retryWithDrag: retryWithDrag,
                                        readAttempts: readAttempts, inputGeneration: inputGeneration)
                        return
                    }
                    if readAttempts < 2 {
                        self.verifyMove(icon: icon, expectedSection: expectedSection,
                                        target: target, retryWithDrag: retryWithDrag,
                                        readAttempts: readAttempts + 1, inputGeneration: inputGeneration)
                        return
                    }
                    self.finishUnsavedMove(icon)
                    return
                }
                self.finishMove()
                return
            }
            guard retryWithDrag,
                  !ControlItem.usesMacOS27Model || inputGeneration == self.nativeInputGeneration else {
                self.assignedSections.removeValue(forKey: icon.id)
                self.refresh()
                self.errorMessage = "macOS did not move \(icon.title). Try again."
                self.finishMove()
                return
            }
            if ControlItem.usesMacOS27Model {
                guard let fresh = self.refreshedIcon(icon),
                      let targetX = Self.insertionX(for: expectedSection,
                                                   iconWidth: fresh.frame.width,
                                                   boundaries: self.boundaryProvider()) else {
                    self.finishUnsavedMove(icon)
                    return
                }
                guard canCommit() else {
                    self.verifyMove(icon: icon, expectedSection: expectedSection,
                                    target: target, retryWithDrag: true,
                                    readAttempts: readAttempts, inputGeneration: inputGeneration)
                    return
                }
                self.move(fresh, toX: targetX, expectedSection: expectedSection,
                          allowNativeRetry: false)
                self.finishMove()
                return
            }
            self.drag(icon.frame, to: CGPoint(x: target.x + icon.frame.width / 2,
                                               y: icon.frame.midY))
            self.verifyMove(icon: icon,
                            expectedSection: expectedSection,
                            target: target,
                            retryWithDrag: false, inputGeneration: inputGeneration)
        }
    }

    private func finishUnsavedMove(_ icon: Icon) {
        assignedSections.removeValue(forKey: icon.id)
        if ControlItem.usesMacOS27Model,
           let bundleID = icon.id.split(separator: "|", maxSplits: 1).first {
            nativeSaveFailures.insert(String(bundleID))
        }
        refresh()
        errorMessage = nativeSaveError ?? "Flux could not verify the icon's new position. Try again."
        finishMove()
    }

    private func saveLayout(for icon: Icon, canCommit: () -> Bool) -> Bool {
        guard ControlItem.usesMacOS27Model else { return true }
        guard let bundleID = icon.id.split(separator: "|", maxSplits: 1).first else { return false }
        let saved = macOS27Hider.recordLayoutChange(for: String(bundleID), canCommit: canCommit)
        if saved {
            nativeSaveFailures.remove(String(bundleID))
            errorMessage = nativeSaveError ?? macOS27Hider.latestError
        }
        return saved
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
        if ControlItem.usesMacOS27Model { Thread.sleep(forTimeInterval: 0.06) }

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
            if ControlItem.usesMacOS27Model { Thread.sleep(forTimeInterval: 0.018) }
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
