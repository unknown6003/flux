import AppKit
import ApplicationServices
import Combine

/// Reads status items and submits all Settings moves to one transaction owner.
@MainActor
final class MenuBarIconManager: ObservableObject {
    typealias Boundaries = (hidden: CGFloat?, alwaysHidden: CGFloat?)

    enum MoveDirection { case towardDrawer, towardClock }
    enum MoveCancellation { case focusLost, closed, screenChanged, escape }

    struct Icon: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String?
        let section: MenuBarSection
        let isMovable: Bool
        let frame: CGRect
        var identity: UUID? = nil

        fileprivate var handle: MenuBarArrangement.Handle { .init(id: id, identity: identity) }
    }

    struct Insertion: Equatable {
        let section: MenuBarSection
        let before: Icon?
        let after: Icon?

        func matches(_ siblings: [Icon]) -> Bool {
            let index = before.flatMap { next in siblings.firstIndex { $0.handle == next.handle } } ?? siblings.count
            return (index < siblings.count ? siblings[index].handle : nil) == before?.handle
                && (index > 0 ? siblings[index - 1].handle : nil) == after?.handle
        }
    }

    @Published private(set) var icons: [Icon] = []
    @Published private(set) var isTrusted = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdatingIcons = false

    var boundaryProvider: () -> Boundaries = { (nil, nil) }
    var chevronBoundaryProvider: () -> CGFloat? = { nil }
    var alwaysHiddenEnabledProvider: () -> Bool = { true }
    var beginProvider: () -> Void = {}
    var endProvider: () -> Void = {}

    private let trustProvider: () -> Bool
    private let injectedHider: MacOS27Hider?
    private let driver = MenuBarNativeDrag()
    private var elements: [String: AXUIElement] = [:]
    private var ownerTopology: [String: [AXUIElement]] = [:]
    private var inventoryReadable = false
    private var readingInventory = false
    private var hiderReads = 0
    private var inventoryError: String?
    private var moveError: String?
    private var isManaging = false
    private var managementGeneration = 0
    private var cancellationGeneration = 0
    private var nativeInputGeneration = 0
    private var readyAfter: TimeInterval = 0
    private var lastMoveReport = "none"
    private var lastMoveVerification = "none"
    private var desiredVisibility: (hidden: Bool, alwaysHidden: Bool, refresh: Bool)?
    private var nativeMoveMonitor: Any?
    private var localInputMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private struct NativeGesture {
        let handle: MenuBarArrangement.Handle
        let element: AXUIElement
        let owner: NSRunningApplication
        let launched: Date?
        let bundleID: String
        let start: CGPoint
        let frame: CGRect
        var dragged = false
    }
    private var nativeGesture: NativeGesture?
    private var nativeImport: Task<Void, Never>?
    private var nativeImportGeneration = 0

    private lazy var macOS27Hider: MacOS27Hider = {
        let hider = injectedHider ?? MacOS27Hider()
        hider.onStatus = { [weak self] _ in self?.publishStatus() }
        hider.onReadState = { [weak self] reading in
            guard let self else { return }
            self.hiderReads += reading ? 1 : -1
            self.publishBusy()
        }
        return hider
    }()

    private lazy var arrangement: MenuBarArrangement = {
        let result = MenuBarArrangement(environment: .init(
            appScoped: ControlItem.usesMacOS27Model,
            read: { [weak self] in self?.readArrangement() },
            canStart: { [weak self] in self?.canStartMove() ?? false },
            inputRevision: { [weak self] in self?.nativeInputGeneration ?? -1 },
            sectionTarget: { [weak self] item, section in
                guard let self, let x = Self.insertionX(for: section, iconWidth: item.frame.width,
                                                       boundaries: self.boundaryProvider()) else { return nil }
                return CGPoint(x: x + item.frame.width / 2, y: item.frame.midY)
            },
            drag: { [weak self] item, target in
                guard let self else { return false }
                let revision = self.nativeInputGeneration
                let generation = self.cancellationGeneration
                let expectedPID = ControlItem.usesMacOS27Model
                    ? Self.appIconIdentity(from: item.handle.id)?.processID : nil
                let posted = await self.driver.perform(from: item.frame, to: target,
                                                 expectedProcessID: expectedPID) { [weak self] in
                    guard let self else { return false }
                    return self.trustProvider() && self.nativeInputGeneration == revision
                        && self.cancellationGeneration == generation
                }
                self.lastMoveReport += "; native=\(self.driver.diagnostics)"
                return posted
            },
            physicalSection: { [weak self] item in
                Self.section(for: item.frame, boundaries: self?.boundaryProvider() ?? (nil, nil))
            },
            assign: { [weak self] item, section, canCommit in
                guard let self, canCommit() else { return false }
                guard ControlItem.usesMacOS27Model else { return true }
                guard let owner = Self.appIconIdentity(from: item.handle.id) else { return false }
                return self.macOS27Hider.recordAppSection(section, for: owner.bundleID, canCommit: canCommit)
                    && self.macOS27Hider.section(for: owner.bundleID) == section
            }))
        result.onBusy = { [weak self] _ in self?.publishBusy() }
        result.onTrace = { [weak self] trace in self?.lastMoveReport += "; \(trace)" }
        result.onResult = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.moveError = nil
                self.lastMoveVerification = "verified and saved"
            case .failure(let failure):
                self.moveError = failure.message
                self.lastMoveVerification = failure.message
            }
            self.refresh()
            self.applyDesiredVisibility()
        }
        return result
    }()

    var canHideWithoutAccess: Bool {
        ControlItem.usesMacOS27Model && macOS27Hider.isAvailable && macOS27Hider.hasSavedLayout
    }

    init(trustProvider: @escaping () -> Bool = { AccessibilityAccess.isGranted() },
         hider: MacOS27Hider? = nil) {
        self.trustProvider = trustProvider
        injectedHider = hider
        observeAppActivation()
        observeInput()
    }

    deinit {
        if let nativeMoveMonitor { NSEvent.removeMonitor(nativeMoveMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        nativeImport?.cancel()
    }

    private func publishBusy() {
        let busy = readingInventory || hiderReads > 0 || arrangement.isBusy
            || nativeGesture != nil || nativeImport != nil
        if isUpdatingIcons != busy { isUpdatingIcons = busy }
    }

    private func publishStatus() {
        let message = moveError ?? inventoryError
            ?? (ControlItem.usesMacOS27Model ? macOS27Hider.latestError : nil)
        if errorMessage != message { errorMessage = message }
    }

    private func observeAppActivation() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                _ = AccessibilityAccess.isGranted(forceRefresh: true)
                self.refresh()
                if ControlItem.usesMacOS27Model { self.macOS27Hider.retry() }
            }
            .store(in: &cancellables)
    }

    func requestAccess() {
        guard !trustProvider() else { refresh(); return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func beginIconManagement() {
        managementGeneration += 1
        isManaging = true
        readyAfter = ProcessInfo.processInfo.systemUptime + 0.5
        guard !ControlItem.usesMacOS27Model || trustProvider() else { refresh(); return }
        beginProvider()
        applyDrawerVisibility(revealHidden: true, revealAlwaysHidden: true, refreshBeforeApplying: false)
        refresh()
        let generation = managementGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isManaging, self.managementGeneration == generation else { return }
            self.refresh()
        }
    }

    func endIconManagement() {
        managementGeneration += 1
        isManaging = false
        cancelPendingMoves()
        endProvider()
        applyDesiredVisibility()
    }

    func cancelPendingMoves(for reason: MoveCancellation = .closed) {
        if reason == .focusLost && driver.isRunning { return }
        cancellationGeneration += 1
        lastMoveReport += "; cancelled=\(reason)"
    }

    func copyMenuBarReport(settingsDrag: String = "none") {
        let report = ControlItem.usesMacOS27Model ? macOS27Hider.diagnostics
            : "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(trustProvider())"
        let boundaries = boundaryProvider()
        let moveReport = """

        Move boundaries: hidden=\(String(describing: boundaries.hidden)), always=\(String(describing: boundaries.alwaysHidden))
        Event posting allowed: \(CGPreflightPostEventAccess())
        Last move request: \(lastMoveReport)
        Last move verification: \(lastMoveVerification)
        Move busy: \(arrangement.isBusy), input revision: \(nativeInputGeneration)
        Management: \(isManaging), cancellation revision: \(cancellationGeneration)
        Settings drag: \(settingsDrag)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report + moveReport, forType: .string)
    }

    func refresh() {
        guard !readingInventory else { return }
        readingInventory = true
        publishBusy()
        defer {
            readingInventory = false
            publishBusy()
            publishStatus()
        }
        isTrusted = trustProvider()
        inventoryReadable = false
        inventoryError = nil
        guard isTrusted else {
            icons = []
            elements.removeAll()
            ownerTopology.removeAll()
            inventoryError = "Allow Accessibility access to manage menu-bar icons."
            return
        }
        if ControlItem.usesMacOS27Model { refreshMacOS27() }
        else { refreshLegacy() }
    }

    private func refreshLegacy() {
        guard let systemUI = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver").first
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "SystemUIServer" }) else {
            inventoryError = "Flux could not find the macOS menu bar."
            return
        }
        let owner = AXUIElementCreateApplication(systemUI.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.2)
        guard let bar = elementAttribute(owner, kAXMenuBarAttribute) else {
            inventoryError = "Flux could not read the macOS menu bar."
            return
        }
        let items = children(of: bar)
        let scope = "system-ui|\(systemUI.processIdentifier)|\(Self.launchToken(for: systemUI.launchDate))|"
        let unchanged = topologyMatches(items, scope: scope)
        var next: [Icon] = []
        var nextElements: [String: AXUIElement] = [:]
        for (index, element) in items.enumerated() {
            guard stringAttribute(element, kAXRoleAttribute) == kAXMenuBarItemRole as String,
                  let frame = frame(of: element) else { continue }
            let identifier = stringAttribute(element, kAXIdentifierAttribute)
            let title = stringAttribute(element, kAXTitleAttribute)
                ?? stringAttribute(element, kAXDescriptionAttribute) ?? "Menu bar item \(index + 1)"
            let source = stringAttribute(element, kAXHelpAttribute)
            guard !isFluxItem(identifier: identifier, title: title, source: source) else { continue }
            let id = scope + String(index)
            next.append(Icon(id: id, title: title, source: source,
                             section: Self.section(for: frame, boundaries: boundaryProvider()),
                             isMovable: true, frame: frame,
                             identity: retainedIdentity(id: id, element: element, unchanged: unchanged)))
            nextElements[id] = element
        }
        ownerTopology = [scope: items]
        replaceInventory(next, elements: nextElements)
    }

    private func refreshMacOS27() {
        var next: [Icon] = []
        var nextElements: [String: AXUIElement] = [:]
        var nextTopology: [String: [AXUIElement]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, !bundleID.hasPrefix("com.apple."),
                  app.activationPolicy != .prohibited, bundleID != Bundle.main.bundleIdentifier else { continue }
            let owner = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(owner, 0.2)
            guard let bar = elementAttribute(owner, kAXExtrasMenuBarAttribute) else { continue }
            let items = children(of: bar)
            let scope = "\(bundleID)|\(app.processIdentifier)|\(Self.launchToken(for: app.launchDate))|"
            let unchanged = topologyMatches(items, scope: scope)
            nextTopology[scope] = items
            for (index, element) in items.enumerated() {
                guard let frame = frame(of: element) else { continue }
                let title = stringAttribute(element, kAXTitleAttribute)
                    ?? stringAttribute(element, kAXDescriptionAttribute) ?? app.localizedName ?? bundleID
                let id = Self.iconID(bundleID: bundleID, processID: app.processIdentifier,
                                     launchDate: app.launchDate, index: index)
                next.append(Icon(id: id, title: title, source: app.localizedName,
                                 section: macOS27Hider.section(for: bundleID) ?? .shown,
                                 isMovable: MenuBarVisibilityPolicy.isAssignable(bundleID), frame: frame,
                                 identity: retainedIdentity(id: id, element: element, unchanged: unchanged)))
                nextElements[id] = element
            }
        }
        next.append(contentsOf: liveActivityIcons())
        ownerTopology = nextTopology
        replaceInventory(next, elements: nextElements)
        if !macOS27Hider.isAvailable {
            inventoryError = "Hiding is unavailable on this macOS build. Flux needs an update."
        }
    }

    private func topologyMatches(_ items: [AXUIElement], scope: String) -> Bool {
        guard let previous = ownerTopology[scope], previous.count == items.count else { return false }
        return zip(previous, items).allSatisfy { CFEqual($0.0, $0.1) }
    }

    private func retainedIdentity(id: String, element: AXUIElement, unchanged: Bool) -> UUID {
        if unchanged, let previous = elements[id], CFEqual(previous, element),
           let identity = icons.first(where: { $0.id == id })?.identity { return identity }
        return UUID()
    }

    private func replaceInventory(_ next: [Icon], elements nextElements: [String: AXUIElement]) {
        let sorted = next.sorted { $0.frame.minX < $1.frame.minX }
        if icons != sorted { icons = sorted }
        elements = nextElements
        inventoryReadable = true
    }

    private func readArrangement() -> [MenuBarArrangement.Item]? {
        refresh()
        guard inventoryReadable else { return nil }
        return icons.filter(\.isMovable).map {
            MenuBarArrangement.Item(handle: $0.handle,
                                    bundleID: Self.appIconIdentity(from: $0.id)?.bundleID ?? "system-ui",
                                    title: $0.title, section: $0.section, frame: $0.frame)
        }
    }

    private func canStartMove() -> Bool {
        trustProvider() && ProcessInfo.processInfo.systemUptime >= readyAfter
            && nativeGesture == nil && nativeImport == nil && inputIsQuiet()
            && visibleMenuWindow() == false
    }

    private func inputIsQuiet() -> Bool {
        !CGEventSource.buttonState(.combinedSessionState, button: .left)
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) >= 0.15
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) >= 0.15
    }

    private func visibleMenuWindow() -> Bool? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid())
                && ($0[kCGWindowLayer as String] as? Int) == NSWindow.Level.popUpMenu.rawValue
        }
    }

    private func submit(_ icon: Icon, destination: MenuBarArrangement.Destination) -> Bool {
        guard !arrangement.isBusy, icon.isMovable,
              destination.section != .alwaysHidden || alwaysHiddenEnabledProvider() else { return false }
        let generation = cancellationGeneration
        let revision = nativeInputGeneration
        moveError = nil
        lastMoveReport = "request \(icon.id) section=\(destination.section.rawValue)"
        lastMoveVerification = "pending"
        let accepted = arrangement.submit(.init(item: icon.handle, destination: destination)) { [weak self] in
            guard let self else { return false }
            return self.trustProvider() && self.cancellationGeneration == generation
                && self.nativeInputGeneration == revision
                && (destination.section != .alwaysHidden || self.alwaysHiddenEnabledProvider())
        }
        publishStatus()
        return accepted
    }

    func move(_ icon: Icon, to section: MenuBarSection) {
        _ = submit(icon, destination: .section(section))
    }

    @discardableResult
    func move(_ icon: Icon, to insertion: Insertion,
              accepting: @escaping (Icon) -> Bool = { _ in true }) -> Bool {
        guard !arrangement.isBusy else { return false }
        refresh()
        guard let current = icons.first(where: { $0.handle == icon.handle }), accepting(current) else { return false }
        let peers = icons.filter { $0.section == insertion.section && $0.id != current.id }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard insertion.matches(peers) else {
            moveError = MenuBarArrangement.Failure.changed.message
            publishStatus()
            return false
        }
        let slot = MenuBarArrangement.Slot(section: insertion.section,
                                           before: insertion.before?.handle, after: insertion.after?.handle)
        return submit(current, destination: .slot(slot))
    }

    func canMove(_ icon: Icon, toward direction: MoveDirection) -> Bool {
        guard icon.isMovable else { return false }
        let peers = icons.filter { $0.section == icon.section }.sorted { $0.frame.minX < $1.frame.minX }
        guard let index = peers.firstIndex(where: { $0.handle == icon.handle }) else { return false }
        return direction == .towardDrawer ? index > 0 : index + 1 < peers.count
    }

    func move(_ icon: Icon, toward direction: MoveDirection) {
        guard !arrangement.isBusy else { return }
        refresh()
        guard let current = icons.first(where: { $0.handle == icon.handle }), canMove(current, toward: direction) else { return }
        let peers = icons.filter { $0.section == current.section }.sorted { $0.frame.minX < $1.frame.minX }
        guard let index = peers.firstIndex(where: { $0.handle == current.handle }) else { return }
        let remaining = peers.filter { $0.id != current.id }
        let slot = direction == .towardDrawer ? index - 1 : index + 1
        let placement = MenuBarArrangement.Slot(section: current.section,
                                               before: slot < remaining.count ? remaining[slot].handle : nil,
                                               after: slot > 0 ? remaining[slot - 1].handle : nil)
        _ = submit(current, destination: .slot(placement))
    }

    func applyDrawerVisibility(revealHidden: Bool, revealAlwaysHidden: Bool,
                               refreshBeforeApplying: Bool = true) {
        desiredVisibility = (revealHidden, revealAlwaysHidden, refreshBeforeApplying)
        applyDesiredVisibility()
    }

    private func applyDesiredVisibility() {
        guard !arrangement.isBusy, nativeGesture == nil, nativeImport == nil,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let visibility = desiredVisibility else { return }
        desiredVisibility = nil
        let hidden = isManaging || visibility.hidden
        let always = isManaging || visibility.alwaysHidden
        if ControlItem.usesMacOS27Model {
            macOS27Hider.apply(revealHidden: hidden, revealAlwaysHidden: always,
                               alwaysHiddenEnabled: alwaysHiddenEnabledProvider(),
                               chevronX: { [weak self] in self?.chevronBoundaryProvider() },
                               alwaysX: { [weak self] in self?.boundaryProvider().alwaysHidden })
        } else {
            if visibility.refresh && icons.isEmpty { refresh() }
            for icon in icons {
                guard let element = elements[icon.id] else { continue }
                setHidden(!Self.isVisible(icon.section, revealHidden: hidden, revealAlwaysHidden: always), on: element)
            }
        }
    }

    private func setHidden(_ hidden: Bool, on element: AXUIElement) {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXHiddenAttribute as CFString, &settable) == .success,
              settable.boolValue else { return }
        _ = AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, NSNumber(value: hidden))
    }

    private func observeInput() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                          .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]
        nativeMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observeInput(event) }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observeInput(event) }
            return event
        }
    }

    private func observeInput(_ event: NSEvent) {
        guard let cg = event.cgEvent,
              cg.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        switch event.type {
        case .leftMouseDown:
            nativeInputGeneration += 1
            cancelNativeImport()
            nativeGesture = nil
            captureNativeGesture(event, cg: cg)
        case .leftMouseDragged:
            if let gesture = nativeGesture, hypot(cg.location.x - gesture.start.x, cg.location.y - gesture.start.y) >= 3 {
                nativeGesture?.dragged = true
            }
        case .leftMouseUp:
            let gesture = nativeGesture
            nativeGesture = nil
            if let gesture, gesture.dragged { importNativeGesture(gesture) }
            else { applyDesiredVisibility() }
        case .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged:
            nativeInputGeneration += 1
            if event.type != .flagsChanged { cancelNativeImport() }
            if event.type != .flagsChanged || !event.modifierFlags.contains(.command) {
                nativeGesture = nil
            }
        default: break
        }
        publishBusy()
    }

    private func captureNativeGesture(_ event: NSEvent, cg: CGEvent) {
        guard ControlItem.usesMacOS27Model, !arrangement.isBusy,
              event.modifierFlags.contains(.command), let primary = NSScreen.screens.first else { return }
        let point = cg.location
        let appKitPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        guard NSScreen.screens.contains(where: { $0.statusItemRegion.contains(appKitPoint) }) else { return }
        refresh()
        let matches = icons.filter { $0.isMovable && $0.frame.contains(point) }
        guard matches.count == 1, let icon = matches.first, let element = elements[icon.id],
              let identity = Self.appIconIdentity(from: icon.id),
              let owner = NSRunningApplication(processIdentifier: identity.processID),
              Self.launchToken(for: owner.launchDate) == identity.launchToken,
              macOS27Hider.canReadPosition(for: identity.bundleID) else { return }
        nativeGesture = NativeGesture(handle: icon.handle, element: element, owner: owner,
                                      launched: owner.launchDate, bundleID: identity.bundleID,
                                      start: point, frame: icon.frame)
    }

    private func cancelNativeImport() {
        nativeImportGeneration += 1
        nativeImport?.cancel()
        nativeImport = nil
    }

    private func importNativeGesture(_ gesture: NativeGesture) {
        cancelNativeImport()
        let generation = nativeImportGeneration
        nativeImport = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.nativeImportGeneration == generation {
                    self.nativeImport = nil
                    self.publishBusy()
                    self.applyDesiredVisibility()
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !self.inputIsQuiet() || self.arrangement.isBusy {
                guard !Task.isCancelled, self.nativeImportGeneration == generation,
                      ProcessInfo.processInfo.systemUptime < deadline else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, self.nativeImportGeneration == generation,
                  !gesture.owner.isTerminated, gesture.owner.launchDate == gesture.launched else { return }
            self.refresh()
            guard let current = self.icons.first(where: { $0.handle == gesture.handle }),
                  let element = self.elements[current.id], CFEqual(element, gesture.element),
                  abs(current.frame.midX - gesture.frame.midX) >= 3 else { return }
            let revision = self.nativeInputGeneration
            let downCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
            let canCommit = {
                !Task.isCancelled && self.nativeInputGeneration == revision && self.inputIsQuiet()
                    && CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown) == downCount
            }
            let saved = self.macOS27Hider.recordAvailableLayoutChanges(for: [gesture.bundleID], canCommit: canCommit)
            if !saved.contains(gesture.bundleID) {
                self.moveError = "Flux could not save the icon's new position. Try again."
            }
            self.refresh()
        }
    }

    static func iconID(bundleID: String, processID: pid_t, launchDate: Date?, index: Int) -> String {
        "\(bundleID)|\(processID)|\(launchToken(for: launchDate))|\(index)"
    }

    static func launchToken(for launchDate: Date?) -> Int64 {
        guard let launchDate else { return 0 }
        return Int64((launchDate.timeIntervalSince1970 * 1_000).rounded())
    }

    static func appIconIdentity(from id: String) ->
        (bundleID: String, processID: pid_t, launchToken: Int64, index: Int)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let processID = Int32(parts[1]),
              let launchToken = Int64(parts[2]),
              let index = Int(parts[3]), index >= 0 else { return nil }
        return (String(parts[0]), pid_t(processID), launchToken, index)
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

    static func insertionMatches(_ current: Icon, placement: Insertion, in icons: [Icon]) -> Bool {
        let siblings = icons.filter { $0.id != current.id && $0.section == placement.section }
        let ordered = (siblings + [current]).sorted { $0.frame.minX < $1.frame.minX }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return false }
        return (index + 1 < ordered.count ? ordered[index + 1].handle : nil) == placement.before?.handle
            && (index > 0 ? ordered[index - 1].handle : nil) == placement.after?.handle
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
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        guard point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
