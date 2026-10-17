import AppKit
import ApplicationServices

// macOS 27 hosts third-party status items in MenuBarAgent. The old width
// trick only creates the system overflow button. This bridge follows the
// MIT-licensed MenuBarHider implementation by happy666End:
// https://github.com/happy666End/MenuBarHider
@objc private protocol MenuBarAssessmentAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

@MainActor
private final class MenuBarAssessment {
    private static let configurationSelector =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var active: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    private var pending: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    var onStatus: ((String?) -> Void)?

    deinit {
        pending?.assertion.invalidate()
        active?.assertion.invalidate()
    }

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
                     RTLD_NOW) != nil,
              let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              assertion.instancesRespond(
                to: #selector(MenuBarAssessmentAssertion.activate(with:completionHandler:))),
              assertion.instancesRespond(to: #selector(MenuBarAssessmentAssertion.invalidate)),
              configuration.instancesRespond(to: Self.configurationSelector) else {
            classes = nil
            return
        }
        classes = (assertion, configuration)
    }

    var isAvailable: Bool { classes != nil }
    var allowed: [String]? { active?.allowed }
    var isRestricting: Bool { active != nil || pending != nil }

    func permitsPositionRead(for bundleID: String) -> Bool {
        pending == nil && (active?.allowed.contains(bundleID) ?? true)
    }

    func restrict(to bundleIDs: [String]) {
        guard let classes else { return }
        guard bundleIDs != active?.allowed else {
            pending?.assertion.invalidate()
            pending = nil
            return
        }
        guard MacOS27Hider.shouldStartAssessment(requested: bundleIDs,
                                                 active: active?.allowed,
                                                 pending: pending?.allowed) else { return }
        let allocated = (classes.configuration as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        guard let configuration = allocated?
            .perform(Self.configurationSelector, with: systemItems,
                     with: bundleIDs as NSArray)?.takeRetainedValue() else {
            onStatus?("MenuBarAgent could not set up hiding.")
            return
        }

        pending?.assertion.invalidate()
        let assertion = unsafeBitCast(classes.assertion.init(),
                                      to: MenuBarAssessmentAssertion.self)
        pending = (assertion, bundleIDs)
        assertion.activate(with: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending?.assertion === assertion else { return }
                self.pending = nil
                if let error {
                    assertion.invalidate()
                    Log.menuBar.error("macOS 27 hiding failed: \(error.localizedDescription, privacy: .public)")
                    self.onStatus?("MenuBarAgent refused hiding: \(error.localizedDescription)")
                } else {
                    self.active?.assertion.invalidate()
                    self.active = (assertion, bundleIDs)
                    self.onStatus?(nil)
                }
            }
        }
    }

    func release() {
        pending?.assertion.invalidate()
        pending = nil
        active?.assertion.invalidate()
        active = nil
    }
}

@MainActor
final class MacOS27Hider {
    typealias PositionScan = (positions: [(bundleID: String, x: CGFloat)], replies: [String])
    private static let alwaysAllowed: Set<String> = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent",
        "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
        "com.apple.Siri", "com.apple.Spotlight", "com.apple.wifi.WiFiAgent",
        "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.flux.menubar",
    ]

    private let assessment = MenuBarAssessment()
    private let trustProvider: () -> Bool
    private let defaults: UserDefaults
    private let positionReader: (String?) -> PositionScan
    private static let layoutKey = "flux.macOS27IconLayout"
    private(set) var hasSavedLayout = false
    var onStatus: ((String?) -> Void)?
    var onReadState: ((Bool) -> Void)?
    private(set) var latestError: String?
    private var hidden = Set<String>()
    private var alwaysHidden = Set<String>()
    private var revealHidden = false
    private var revealAlwaysHidden = false
    private var alwaysHiddenEnabled = true
    private var chevronX: () -> CGFloat? = { nil }
    private var alwaysX: () -> CGFloat? = { nil }
    private var generation = 0
    private var layoutScanPending = false
    private var layoutReadyAt: TimeInterval = 0
    private var overClock = false
    private var isManagingVisibility = false
    private var mouseMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var clockFrameCache: (frame: CGRect?, date: Date)?
    private var lastAccessGranted = AXIsProcessTrusted()
    private var accessGeneration = 0
    private var lastCollapsedScan = "No collapsed scan has run."
    private var lastCollapsedRequest = "No collapsed hide request has run."
    private var runningBundleIDs = Set<String>()

    var diagnostics: String {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.flux.menubar")
        return """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Flux: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        Accessibility: \(trustProvider())
        Accessibility system flag: \(AXIsProcessTrusted())
        Hiding interface: \(assessment.isAvailable)
        Saved icon layout: \(hasSavedLayout)
        Install matches registered app: \(registered?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL)
        Current reveal: hidden=\(revealHidden), always=\(revealAlwaysHidden)
        Clock bypass: \(overClock)
        Active hide request: \(assessment.allowed != nil)
        Last error: \(latestError ?? "none")
        Last collapsed request: \(lastCollapsedRequest)
        Last collapsed scan:
        \(lastCollapsedScan)
        """
    }

    init(defaults: UserDefaults = .standard,
         trustProvider: (() -> Bool)? = nil,
         positionReader: (() -> PositionScan)? = nil) {
        self.trustProvider = trustProvider ?? { AccessibilityAccess.isGranted() }
        self.defaults = defaults
        if let positionReader {
            self.positionReader = { _ in positionReader() }
        } else {
            self.positionReader = { Self.scanPositions(for: $0) }
        }
        if let layout = defaults.dictionary(forKey: Self.layoutKey),
           let hidden = layout["hidden"] as? [String],
           let alwaysHidden = layout["alwaysHidden"] as? [String] {
            self.hidden = Set(hidden.filter { !Self.alwaysAllowed.contains($0) && !$0.hasPrefix("com.apple.") })
            self.alwaysHidden = Set(alwaysHidden).intersection(self.hidden)
            hasSavedLayout = true
        }
        assessment.onStatus = { [weak self] message in
            self?.latestError = message
            self?.onStatus?(message)
            if let self, !self.revealHidden && !self.revealAlwaysHidden {
                self.lastCollapsedRequest = message ?? "macOS accepted the hide request."
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.runningBundleIDs = Self.runningApplicationBundleIDs()
                    self.reconcile()
                }
            })
        }
        // Register first, then take the initial snapshot so a launch between the
        // two steps cannot leave a running app out of the allow list.
        runningBundleIDs = Self.runningApplicationBundleIDs()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] _ in
            Task { @MainActor in self?.updateClockHover() }
        }
        if trustProvider == nil {
            let initialAccessGeneration = accessGeneration
            Task { [weak self] in
                let granted = await Task.detached(priority: .utility) {
                    AccessibilityAccess.isGranted()
                }.value
                guard let self, self.accessGeneration == initialAccessGeneration else { return }
                self.lastAccessGranted = granted
                if !granted && self.hasSavedLayout {
                    Log.menuBar.info("Using saved icon layout without Accessibility access")
                }
            }
        }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        for observer in appObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var isAvailable: Bool { assessment.isAvailable }

    func section(for bundleID: String) -> MenuBarSection? {
        guard hasSavedLayout else { return nil }
        if alwaysHidden.contains(bundleID) { return .alwaysHidden }
        return hidden.contains(bundleID) ? .hidden : .shown
    }

    func canReadPosition(for bundleID: String) -> Bool {
        assessment.permitsPositionRead(for: bundleID)
    }

    @discardableResult
    func recordLayoutChange(for bundleID: String, canCommit: () -> Bool = { true }) -> Bool {
        recordLayoutChanges(for: [bundleID], canCommit: canCommit)
    }

    @discardableResult
    func recordSection(_ section: MenuBarSection, for bundleID: String,
                       canCommit: () -> Bool = { true }) -> Bool {
        commitLayoutChanges(for: [bundleID], requireAll: true,
                            assignments: [bundleID: section], canCommit: canCommit) == [bundleID]
    }

    @discardableResult
    func recordLayoutChanges(for bundleIDs: Set<String>, canCommit: () -> Bool = { true }) -> Bool {
        commitLayoutChanges(for: bundleIDs, requireAll: true, canCommit: canCommit) == bundleIDs
    }

    func recordAvailableLayoutChanges(for bundleIDs: Set<String>, canCommit: () -> Bool) -> Set<String> {
        commitLayoutChanges(for: bundleIDs, requireAll: false, canCommit: canCommit)
    }

    private func commitLayoutChanges(for bundleIDs: Set<String>, requireAll: Bool,
                                     assignments: [String: MenuBarSection] = [:],
                                     canCommit: () -> Bool) -> Set<String> {
        guard !bundleIDs.isEmpty,
              bundleIDs.allSatisfy({ !$0.hasPrefix("com.apple.") && !Self.alwaysAllowed.contains($0) }),
              let chevronX = chevronX() else { return [] }
        onReadState?(true)
        defer { onReadState?(false) }
        guard trustProvider() else { return [] }
        let positions = hasSavedLayout
            ? bundleIDs.sorted().flatMap { bundleID in
                positionReader(bundleID).positions.filter { $0.bundleID == bundleID }
            }
            : positionReader(nil).positions
        let available = bundleIDs.intersection(Set(positions.map(\.bundleID)))
        guard !available.isEmpty, (!requireAll && hasSavedLayout) || available == bundleIDs,
              canCommit() else { return [] }
        generation += 1
        layoutScanPending = false
        updateLayout(from: positions, chevronX: chevronX, assignments: assignments)
        reconcile()
        return available
    }

    static func hiddenBundleIDs(_ positions: [(bundleID: String, x: CGFloat)],
                                leftOf boundary: CGFloat?) -> Set<String> {
        guard let boundary else { return [] }
        let groups = Dictionary(grouping: positions) { $0.bundleID }
        return Set(groups.compactMap { id, items in
            items.allSatisfy { $0.x < boundary } ? id : nil
        })
    }

    static func applyingSectionAssignments(
        _ assignments: [String: MenuBarSection],
        hidden: Set<String>,
        alwaysHidden: Set<String>
    ) -> (hidden: Set<String>, alwaysHidden: Set<String>) {
        var hidden = hidden
        var alwaysHidden = alwaysHidden
        for (bundleID, section) in assignments {
            if section == .shown { hidden.remove(bundleID) }
            else { hidden.insert(bundleID) }
            if section == .alwaysHidden { alwaysHidden.insert(bundleID) }
            else { alwaysHidden.remove(bundleID) }
        }
        return (hidden, alwaysHidden.intersection(hidden))
    }

    static func allowedBundleIDs(running: Set<String>, excluded: Set<String>) -> [String] {
        running.subtracting(excluded).union(alwaysAllowed).sorted()
    }

    static func shouldStartAssessment(requested: [String], active: [String]?, pending: [String]?) -> Bool {
        requested != active && requested != pending
    }

    private static func runningApplicationBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    nonisolated static func completePositions(for bundleID: String, centers: [CGFloat?]) -> [(bundleID: String, x: CGFloat)] {
        guard centers.allSatisfy({ $0 != nil }) else { return [] }
        return centers.compactMap { $0.map { (bundleID, $0) } }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(owner, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func value(_ owner: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(owner, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    func apply(revealHidden: Bool, revealAlwaysHidden: Bool,
               alwaysHiddenEnabled: Bool = true,
               chevronX: @escaping () -> CGFloat?, alwaysX: @escaping () -> CGFloat?) {
        isManagingVisibility = true
        self.revealHidden = revealHidden
        self.revealAlwaysHidden = revealAlwaysHidden
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.chevronX = chevronX
        self.alwaysX = alwaysX
        if hasSavedLayout && assessment.isAvailable {
            generation += 1
            layoutScanPending = false
            reconcile()
        } else {
            retry()
        }
    }

    func retry() {
        guard isManagingVisibility else { return }
        generation += 1
        if hasSavedLayout {
            layoutScanPending = false
            guard assessment.isAvailable else {
                latestError = "This macOS build does not provide the menu-bar hiding interface."
                onStatus?(latestError)
                return
            }
            onReadState?(true)
            defer { onReadState?(false) }
            refreshAccess()
            latestError = lastAccessGranted ? nil
                : "Using the saved icon layout. Allow Accessibility to change it."
            onStatus?(latestError)
            if !lastAccessGranted {
                Log.menuBar.info("Using saved icon layout without Accessibility access")
            }
            if !revealHidden && !revealAlwaysHidden {
                lastCollapsedScan = "Using saved icon assignments. No layout edit was requested."
            }
            reconcile()
            return
        }
        let current = generation
        layoutScanPending = true
        releaseAssessment()
        let delay = max(0, layoutReadyAt - ProcessInfo.processInfo.systemUptime)
        scanAfterLayout(generation: current, attempts: 0, delay: delay)
    }

    private func releaseAssessment() {
        if assessment.isRestricting {
            layoutReadyAt = ProcessInfo.processInfo.systemUptime + 0.35
        }
        assessment.release()
    }

    private func scanAfterLayout(generation: Int, attempts: Int, delay: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            let remaining = self.layoutReadyAt - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                self.scanAfterLayout(generation: generation, attempts: attempts, delay: remaining)
                return
            }
            self.onReadState?(true)
            defer { self.onReadState?(false) }
            guard self.assessment.isAvailable else {
                self.layoutScanPending = false
                let message = "This macOS build does not provide the menu-bar hiding interface."
                self.latestError = message
                self.onStatus?(message)
                return
            }
            self.refreshAccess()
            guard self.lastAccessGranted else {
                self.layoutScanPending = false
                let message = self.hasSavedLayout
                    ? "Using the saved icon layout. Allow Accessibility to change it."
                    : "Allow Accessibility once to save your menu-bar icon layout."
                self.latestError = message
                self.onStatus?(message)
                if self.hasSavedLayout {
                    Log.menuBar.info("Using saved icon layout without Accessibility access")
                }
                if !self.revealHidden && !self.revealAlwaysHidden {
                    self.lastCollapsedScan = "Accessibility is off. Saved layout=\(self.hasSavedLayout)."
                }
                self.reconcile()
                return
            }
            guard let chevronX = self.chevronX() else {
                if attempts < 5 { self.scanAfterLayout(generation: generation, attempts: attempts + 1) }
                else {
                    self.layoutScanPending = false
                    if !self.revealHidden && !self.revealAlwaysHidden {
                        self.lastCollapsedScan = "Flux could not read its arrow position after six attempts."
                        self.latestError = self.lastCollapsedScan
                        self.onStatus?(self.latestError)
                    }
                    self.reconcile()
                }
                return
            }
            self.latestError = nil
            self.onStatus?(nil)
            let scan = self.positionReader(nil)
            let positions = scan.positions
            if !self.hasSavedLayout && !positions.isEmpty {
                self.updateLayout(from: positions, chevronX: chevronX)
            }
            if !self.revealHidden && !self.revealAlwaysHidden {
                self.lastCollapsedScan = """
                Arrow x: \(chevronX)
                Icon positions: \(positions.count)
                Hidden app IDs: \(self.hidden.sorted().joined(separator: ", "))
                Positions: \(positions.map { "\($0.bundleID)=\($0.x)" }.sorted().joined(separator: ", "))
                AX replies: \(scan.replies.sorted().joined(separator: "; "))
                """
            }
            self.layoutScanPending = false
            self.reconcile()
        }
    }

    private func updateLayout(from positions: [(bundleID: String, x: CGFloat)],
                              chevronX: CGFloat,
                              assignments: [String: MenuBarSection] = [:]) {
        let readIDs = Set(positions.map(\.bundleID))
        hidden = hidden.subtracting(readIDs)
            .union(Self.hiddenBundleIDs(positions, leftOf: chevronX))
        alwaysHidden = alwaysHidden.subtracting(readIDs)
            .union(alwaysHiddenEnabled ? Self.hiddenBundleIDs(positions, leftOf: alwaysX()) : [])
            .intersection(hidden)
        let assigned = Self.applyingSectionAssignments(assignments,
                                                       hidden: hidden,
                                                       alwaysHidden: alwaysHidden)
        hidden = assigned.hidden
        alwaysHidden = assigned.alwaysHidden
        defaults.set(["hidden": hidden.sorted(), "alwaysHidden": alwaysHidden.sorted()],
                     forKey: Self.layoutKey)
        hasSavedLayout = true
    }

    private func refreshAccess() {
        accessGeneration += 1
        lastAccessGranted = trustProvider()
    }

    private func reconcile() {
        guard isManagingVisibility else { return }
        guard !overClock else {
            releaseAssessment()
            return
        }
        guard !layoutScanPending else { return }
        guard assessment.isAvailable, hasSavedLayout else {
            releaseAssessment()
            return
        }
        let excluded = revealAlwaysHidden ? Set<String>()
            : (revealHidden ? (alwaysHiddenEnabled ? alwaysHidden : []) : hidden)
        guard !excluded.isEmpty else {
            if !revealHidden && !revealAlwaysHidden {
                lastCollapsedRequest = "No apps were found to hide."
            }
            releaseAssessment()
            return
        }
        let allowed = Self.allowedBundleIDs(running: runningBundleIDs, excluded: excluded)
        if !revealHidden && !revealAlwaysHidden {
            lastCollapsedRequest = "Requested hiding \(excluded.count) apps."
        }
        assessment.restrict(to: allowed)
    }

    /// Each app owns its AXExtrasMenuBar on macOS 27. One app can expose more
    /// than one icon; an icon in Shown keeps that whole app on the allow list.
    private static func scanPositions(for bundleID: String? = nil) -> PositionScan {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app
            -> (pid: pid_t, id: String)? in
            guard let id = app.bundleIdentifier,
                  bundleID == nil || bundleID == id,
                  !id.hasPrefix("com.apple."),
                  !alwaysAllowed.contains(id),
                  app.activationPolicy != .prohibited else { return nil }
            return (app.processIdentifier, id)
        }
        let lock = NSLock()
        var result: [(bundleID: String, x: CGFloat)] = []
        var replies: [String] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            func read(_ owner: AXUIElement, _ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(owner, name as CFString, &value)
                if status != .success {
                    lock.lock()
                    replies.append("\(apps[index].id) \(name)=\(status.rawValue)")
                    lock.unlock()
                }
                return status == .success ? value : nil
            }
            let app = AXUIElementCreateApplication(apps[index].pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let barValue = read(app, kAXExtrasMenuBarAttribute),
                  CFGetTypeID(barValue) == AXUIElementGetTypeID(),
                  let children = read(barValue as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
            else { return }
            let centers: [CGFloat?] = children.map { child in
                guard let position = read(child, kAXPositionAttribute),
                      CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = read(child, kAXSizeAttribute),
                      CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                      AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                      dimensions.width > 0 else { return nil }
                return point.x + dimensions.width / 2
            }
            lock.lock()
            result.append(contentsOf: completePositions(for: apps[index].id, centers: centers))
            lock.unlock()
        }
        return (result, replies)
    }

    // Assessment mode also blocks Notification Center. Lift the rule while
    // the pointer is on the clock, then restore it as soon as the pointer leaves.
    private func updateClockHover() {
        let point = NSEvent.mouseLocation
        let inMenuBar = NSScreen.screens.contains {
            $0.frame.contains(point) && point.y >= $0.frame.maxY - $0.menuBarThickness
        }
        let nearClock = NSScreen.screens.contains {
            $0.frame.contains(point) && point.x >= $0.frame.maxX - 180
        }
        let next = inMenuBar && (clockFrame()?.contains(point) ?? nearClock)
        guard next != overClock else { return }
        overClock = next
        reconcile()
    }

    private func clockFrame() -> CGRect? {
        if let cached = clockFrameCache,
           Date().timeIntervalSince(cached.date) < 2 { return cached.frame }
        // Mouse movement uses the grant read during layout or lifecycle checks.
        guard lastAccessGranted else { return nil }
        // A missing clock must not trigger an AX scan on every mouse move.
        clockFrameCache = (nil, Date())
        onReadState?(true)
        defer { onReadState?(false) }
        guard let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = Self.element(app, kAXExtrasMenuBarAttribute),
              let groups = Self.attribute(bar, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for group in groups {
            guard let children = Self.attribute(group, kAXChildrenAttribute) as? [AXUIElement]
            else { continue }
            for child in children {
                guard Self.attribute(child, kAXIdentifierAttribute) as? String
                        == "com.apple.menuextra.clock",
                      let position = Self.value(child, kAXPositionAttribute),
                      let size = Self.value(child, kAXSizeAttribute) else { continue }
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position, .cgPoint, &origin),
                      AXValueGetValue(size, .cgSize, &dimensions),
                      let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                        ?? NSScreen.screens.first else { return nil }
                let frame = CGRect(x: origin.x,
                                   y: screen.frame.height - origin.y - dimensions.height,
                                   width: dimensions.width, height: dimensions.height)
                clockFrameCache = (frame, Date())
                return frame
            }
        }
        return nil
    }
}
