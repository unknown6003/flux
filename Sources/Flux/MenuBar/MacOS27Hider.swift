import AppKit
import ApplicationServices

/// App visibility is independent of the system-owned physical icon order.
struct MenuBarVisibilityPolicy: Equatable {
    static let alwaysAllowed: Set<String> = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent",
        "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
        "com.apple.Siri", "com.apple.Spotlight", "com.apple.wifi.WiFiAgent",
        "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.flux.menubar",
    ]

    private(set) var hidden = Set<String>()
    private(set) var alwaysHidden = Set<String>()
    private(set) var hasSavedLayout = false

    init(document: [String: Any]? = nil) {
        guard let document,
              document["schemaVersion"] == nil || document["schemaVersion"] as? Int == 2,
              let hidden = document["hidden"] as? [String],
              let alwaysHidden = document["alwaysHidden"] as? [String] else { return }
        self.hidden = Set(hidden.filter(Self.isAssignable))
        self.alwaysHidden = Set(alwaysHidden.filter(Self.isAssignable)).intersection(self.hidden)
        hasSavedLayout = true
    }

    static func isAssignable(_ bundleID: String) -> Bool {
        !bundleID.isEmpty
            && bundleID == bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            && !bundleID.hasPrefix("com.apple.")
            && !alwaysAllowed.contains(bundleID)
    }

    func section(for bundleID: String) -> MenuBarSection {
        if alwaysHidden.contains(bundleID) { return .alwaysHidden }
        return hidden.contains(bundleID) ? .hidden : .shown
    }

    @discardableResult
    mutating func assign(_ section: MenuBarSection, to bundleID: String) -> Bool {
        guard Self.isAssignable(bundleID) else { return false }
        if section == .shown { hidden.remove(bundleID) }
        else { hidden.insert(bundleID) }
        if section == .alwaysHidden { alwaysHidden.insert(bundleID) }
        else { alwaysHidden.remove(bundleID) }
        hasSavedLayout = true
        return true
    }

    func excluded(revealHidden: Bool, revealAlwaysHidden: Bool,
                  alwaysHiddenEnabled: Bool) -> Set<String> {
        if revealAlwaysHidden { return [] }
        if revealHidden { return alwaysHiddenEnabled ? alwaysHidden : [] }
        return hidden
    }

    var document: [String: Any] {
        ["schemaVersion": 2, "hidden": hidden.sorted(), "alwaysHidden": alwaysHidden.sorted()]
    }
}

// macOS 27 hosts third-party status items in MenuBarAgent. The old width
// trick only creates the system overflow button. This bridge follows the
// MIT-licensed MenuBarHider implementation by happy666End:
// https://github.com/happy666End/MenuBarHider
@objc private protocol MenuBarAssessmentAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

enum MenuBarAssessmentPolicy {
    static func shouldStart(requested: [String], active: [String]?, pending: [String]?) -> Bool {
        requested != active && requested != pending
    }
}

@MainActor
private final class MenuBarAssessment {
    private static let configurationSelector =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var active: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    private var pending: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    private var pendingTimeout: DispatchWorkItem?
    var onStatus: ((String?) -> Void)?

    deinit {
        pendingTimeout?.cancel()
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
            pendingTimeout?.cancel()
            pendingTimeout = nil
            pending?.assertion.invalidate()
            pending = nil
            return
        }
        guard MenuBarAssessmentPolicy.shouldStart(requested: bundleIDs,
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

        pendingTimeout?.cancel()
        pending?.assertion.invalidate()
        let assertion = unsafeBitCast(classes.assertion.init(),
                                      to: MenuBarAssessmentAssertion.self)
        pending = (assertion, bundleIDs)
        let timeout = DispatchWorkItem { [weak self, weak assertion] in
            guard let self, let assertion,
                  self.pending?.assertion === assertion else { return }
            self.pending = nil
            self.pendingTimeout = nil
            assertion.invalidate()
            self.onStatus?("MenuBarAgent did not confirm the hiding request within 10 seconds.")
        }
        pendingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        assertion.activate(with: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending?.assertion === assertion else { return }
                self.pendingTimeout?.cancel()
                self.pendingTimeout = nil
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
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pending?.assertion.invalidate()
        pending = nil
        active?.assertion.invalidate()
        active = nil
    }
}

@MainActor
final class MacOS27Hider {
    typealias PositionScan = (positions: [(bundleID: String, x: CGFloat)], replies: [String])
    private static let alwaysAllowed = MenuBarVisibilityPolicy.alwaysAllowed

    private let assessment = MenuBarAssessment()
    private let trustProvider: () -> Bool
    private let defaults: UserDefaults
    private let positionReader: (String?) -> PositionScan
    private static let layoutKey = "flux.macOS27IconLayout"
    var hasSavedLayout: Bool { policy.hasSavedLayout }
    var onStatus: ((String?) -> Void)?
    var onReadState: ((Bool) -> Void)?
    private(set) var latestError: String?
    private var policy: MenuBarVisibilityPolicy
    private var revealHidden = false
    private var revealAlwaysHidden = false
    private var alwaysHiddenEnabled = true
    private var chevronX: () -> CGFloat? = { nil }
    private var alwaysX: () -> CGFloat? = { nil }
    private var overClock = false
    private var isManagingVisibility = false
    private var mouseMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var clockFrameCache: (frame: CGRect?, date: Date)?
    private var lastAccessGranted = AXIsProcessTrusted()
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
        policy = MenuBarVisibilityPolicy(document: defaults.dictionary(forKey: Self.layoutKey))
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
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        for observer in appObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var isAvailable: Bool { assessment.isAvailable }

    func section(for bundleID: String) -> MenuBarSection? {
        policy.section(for: bundleID)
    }

    func canReadPosition(for bundleID: String) -> Bool {
        assessment.permitsPositionRead(for: bundleID)
    }

    @discardableResult
    func recordLayoutChange(for bundleID: String, canCommit: () -> Bool = { true }) -> Bool {
        recordLayoutChanges(for: [bundleID], canCommit: canCommit)
    }

    /// MenuBarAgent visibility is app-scoped, so every icon from this bundle
    /// follows the selected Settings section.
    @discardableResult
    func recordAppSection(_ section: MenuBarSection, for bundleID: String,
                          canCommit: () -> Bool = { true }) -> Bool {
        guard MenuBarVisibilityPolicy.isAssignable(bundleID), canCommit() else { return false }
        guard assessment.isAvailable else {
            setError("This macOS build does not provide the menu-bar hiding interface.")
            return false
        }
        policy.assign(section, to: bundleID)
        persistPolicy()
        setError(nil)
        reconcile()
        return true
    }

    @discardableResult
    func recordLayoutChanges(for bundleIDs: Set<String>, canCommit: () -> Bool = { true }) -> Bool {
        commitLayoutChanges(for: bundleIDs, requireAll: true, canCommit: canCommit) == bundleIDs
    }

    func recordAvailableLayoutChanges(for bundleIDs: Set<String>, canCommit: () -> Bool) -> Set<String> {
        commitLayoutChanges(for: bundleIDs, requireAll: false, canCommit: canCommit)
    }

    private func commitLayoutChanges(for bundleIDs: Set<String>, requireAll: Bool,
                                     canCommit: () -> Bool) -> Set<String> {
        guard !bundleIDs.isEmpty, bundleIDs.allSatisfy(MenuBarVisibilityPolicy.isAssignable),
              let chevronX = chevronX(), chevronX.isFinite else { return [] }
        onReadState?(true)
        defer { onReadState?(false) }
        guard trustProvider() else { return [] }
        var positions: [(bundleID: String, x: CGFloat)] = []
        for bundleID in bundleIDs.sorted() where canReadPosition(for: bundleID) {
            let appPositions = positionReader(bundleID).positions.filter { $0.bundleID == bundleID }
            guard !appPositions.isEmpty, appPositions.allSatisfy({ $0.x.isFinite }) else { continue }
            positions += appPositions
        }
        let available = Set(positions.map(\.bundleID))
        guard !available.isEmpty, !requireAll || available == bundleIDs,
              canCommit() else { return [] }
        let hidden = Self.hiddenBundleIDs(positions, leftOf: chevronX)
        let alwaysHidden = alwaysHiddenEnabled
            ? Self.hiddenBundleIDs(positions, leftOf: alwaysX()) : []
        for bundleID in available {
            let section: MenuBarSection = hidden.contains(bundleID)
                ? (alwaysHidden.contains(bundleID) ? .alwaysHidden : .hidden) : .shown
            policy.assign(section, to: bundleID)
        }
        persistPolicy()
        lastCollapsedScan = "Imported an observed native drag for: \(available.sorted().joined(separator: ", "))"
        setError(nil)
        reconcile()
        return available
    }

    private func persistPolicy() {
        defaults.set(policy.document, forKey: Self.layoutKey)
    }

    private func setError(_ message: String?) {
        latestError = message
        onStatus?(message)
    }

    static func hiddenBundleIDs(_ positions: [(bundleID: String, x: CGFloat)],
                                leftOf boundary: CGFloat?) -> Set<String> {
        guard let boundary, boundary.isFinite else { return [] }
        let groups = Dictionary(grouping: positions) { $0.bundleID }
        return Set(groups.compactMap { id, items in
            items.allSatisfy { $0.x.isFinite && $0.x < boundary } ? id : nil
        })
    }

    static func applyingSectionAssignments(
        _ assignments: [String: MenuBarSection],
        hidden: Set<String>,
        alwaysHidden: Set<String>
    ) -> (hidden: Set<String>, alwaysHidden: Set<String>) {
        var policy = MenuBarVisibilityPolicy(document: ["hidden": Array(hidden),
                                                       "alwaysHidden": Array(alwaysHidden)])
        for (bundleID, section) in assignments { policy.assign(section, to: bundleID) }
        return (policy.hidden, policy.alwaysHidden)
    }

    static func allowedBundleIDs(running: Set<String>, excluded: Set<String>) -> [String] {
        running.subtracting(excluded).union(alwaysAllowed).sorted()
    }

    private static func runningApplicationBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    nonisolated static func completePositions(for bundleID: String, centers: [CGFloat?]) -> [(bundleID: String, x: CGFloat)] {
        guard centers.allSatisfy({ $0?.isFinite == true }) else { return [] }
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
        reconcile()
    }

    func retry() {
        guard isManagingVisibility else { return }
        lastAccessGranted = trustProvider()
        guard assessment.isAvailable else {
            setError("This macOS build does not provide the menu-bar hiding interface.")
            assessment.release()
            return
        }
        setError(hasSavedLayout && !lastAccessGranted
                 ? "Using the saved icon layout. Allow Accessibility to change it." : nil)
        lastCollapsedScan = "Using app assignments. No physical layout scan was requested."
        reconcile()
    }

    private func releaseAssessment() {
        assessment.release()
    }

    private func reconcile() {
        guard isManagingVisibility else { return }
        guard !overClock else {
            releaseAssessment()
            return
        }
        guard assessment.isAvailable, hasSavedLayout else {
            releaseAssessment()
            return
        }
        let excluded = policy.excluded(revealHidden: revealHidden,
                                       revealAlwaysHidden: revealAlwaysHidden,
                                       alwaysHiddenEnabled: alwaysHiddenEnabled)
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
