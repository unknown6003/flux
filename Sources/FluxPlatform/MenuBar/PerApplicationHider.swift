import AppKit
import ApplicationServices
import FluxCore

// macOS 27 hosts third-party status items in MenuBarAgent, and a wide spacer
// only creates the system overflow button. Flux 0.21.35 shipped this bridge;
// it follows the MIT-licensed MenuBarHider by happy666End:
// https://github.com/happy666End/MenuBarHider
@objc private protocol MenuBarAssessmentAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping @Sendable (NSError?) -> Void)
    func invalidate()
}

/// Hides whole apps on macOS 27 with a MenuBarAgent allow list. Unknown and
/// newly launched apps stay visible until the next reconcile, which runs on
/// launch, quit and wake. The assertion ends when Flux stops or exits.
@MainActor public final class PerApplicationHider {
    /// System agents allowed even when they are not in the running list.
    /// The user can still hide those that are not pinned by the system.
    public nonisolated static let systemAllowed: Set<String> = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent",
        "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
        "com.apple.Siri", "com.apple.Spotlight", "com.apple.wifi.WiFiAgent",
        "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.flux.menubar",
    ]
    private static let configurationSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")

    /// True when macOS confirmed the latest request, false when it refused or timed out.
    public var onResult: (@MainActor (Bool) -> Void)?
    public var isAvailable: Bool { classes != nil }
    public private(set) var activeAllowList: [String]?

    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var active: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    private var pending: (assertion: MenuBarAssessmentAssertion, allowed: [String])?
    private var pendingTimeout: Task<Void, Never>?
    private var policy = VisibilityPolicy()
    private var reveal: MenuBarReveal = .all
    private var alwaysHiddenEnabled = true
    private var managing = false
    private var overClock = false
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var clockFrameCache: (frame: CGRect?, date: Date)?

    public init() {
        guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil,
              let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              assertion.instancesRespond(to: #selector(MenuBarAssessmentAssertion.activate(with:completionHandler:))),
              assertion.instancesRespond(to: #selector(MenuBarAssessmentAssertion.invalidate)),
              configuration.instancesRespond(to: Self.configurationSelector) else {
            classes = nil
            return
        }
        classes = (assertion, configuration)
    }

    public func apply(policy: VisibilityPolicy, reveal: MenuBarReveal, alwaysHiddenEnabled: Bool) {
        self.policy = policy; self.reveal = reveal; self.alwaysHiddenEnabled = alwaysHiddenEnabled
        if !managing {
            managing = true
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didWakeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcile() }
                })
            }
        }
        reconcile()
    }

    public func stop() {
        managing = false
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        removeMouseMonitor()
        overClock = false
        releaseAssertion()
    }

    /// The pure allow list for a running set. System agents stay allowed
    /// unless the user hid them. Pinned owners are never in `concealed`.
    public nonisolated static func allowList(running: Set<String>, concealed: Set<ApplicationID>) -> [String] {
        running.union(systemAllowed).subtracting(concealed.map(\.rawValue)).sorted()
    }

    private func reconcile() {
        guard managing, isAvailable else { releaseAssertion(); return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let concealed = policy.concealedApplications(running: Set(running.compactMap(ApplicationID.init(rawValue:))),
                                                     reveal: reveal, alwaysHiddenEnabled: alwaysHiddenEnabled)
        guard !concealed.isEmpty else {
            removeMouseMonitor(); overClock = false
            releaseAssertion()
            return
        }
        installMouseMonitor()
        // Assessment mode also blocks Notification Center. Lift it while the
        // pointer is on the clock.
        if overClock { releaseAssertion(); return }
        restrict(to: Self.allowList(running: running, concealed: concealed))
    }

    private func restrict(to allowed: [String]) {
        guard let classes else { return }
        if allowed == active?.allowed {
            cancelPending()
            return
        }
        if allowed == pending?.allowed { return }
        let allocated = (classes.configuration as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        guard let configuration = allocated?.perform(Self.configurationSelector, with: systemItems,
                                                     with: allowed as NSArray)?.takeRetainedValue() else {
            onResult?(false)
            return
        }
        cancelPending()
        let assertion = unsafeBitCast(classes.assertion.init(), to: MenuBarAssessmentAssertion.self)
        pending = (assertion, allowed)
        let token = ObjectIdentifier(assertion)
        pendingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.finish(token, failed: true)
        }
        assertion.activate(with: configuration) { [weak self] error in
            let failed = error != nil
            Task { @MainActor in self?.finish(token, failed: failed) }
        }
    }

    private func finish(_ token: ObjectIdentifier, failed: Bool) {
        guard let pending, ObjectIdentifier(pending.assertion) == token else { return }
        pendingTimeout?.cancel(); pendingTimeout = nil
        self.pending = nil
        if failed {
            pending.assertion.invalidate()
        } else {
            active?.assertion.invalidate()
            active = pending
            activeAllowList = pending.allowed
        }
        onResult?(!failed)
    }

    private func cancelPending() {
        pendingTimeout?.cancel(); pendingTimeout = nil
        pending?.assertion.invalidate()
        pending = nil
    }

    private func releaseAssertion() {
        cancelPending()
        active?.assertion.invalidate()
        active = nil
        activeAllowList = nil
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClockHover() }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func updateClockHover() {
        let point = NSEvent.mouseLocation
        let inMenuBar = NSScreen.screens.contains(where: {
            $0.frame.contains(point) && point.y >= $0.frame.maxY - max($0.frame.maxY - $0.visibleFrame.maxY, NSStatusBar.system.thickness)
        })
        let nearClock = NSScreen.screens.contains(where: {
            $0.frame.contains(point) && point.x >= $0.frame.maxX - 180
        })
        let next = inMenuBar && (clockFrame()?.contains(point) ?? nearClock)
        guard next != overClock else { return }
        overClock = next
        reconcile()
    }

    private func clockFrame() -> CGRect? {
        if let cached = clockFrameCache, Date().timeIntervalSince(cached.date) < 2 { return cached.frame }
        clockFrameCache = (nil, Date())
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = Self.element(app, kAXExtrasMenuBarAttribute),
              let groups = Self.attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for group in groups {
            guard let children = Self.attribute(group, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                guard Self.attribute(child, kAXIdentifierAttribute) as? String == "com.apple.menuextra.clock",
                      let position = Self.value(child, kAXPositionAttribute),
                      let size = Self.value(child, kAXSizeAttribute) else { continue }
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position, .cgPoint, &origin),
                      AXValueGetValue(size, .cgSize, &dimensions),
                      let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
                else { return nil }
                let frame = CGRect(x: origin.x, y: screen.frame.height - origin.y - dimensions.height,
                                   width: dimensions.width, height: dimensions.height)
                clockFrameCache = (frame, Date())
                return frame
            }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func value(_ owner: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(owner, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
