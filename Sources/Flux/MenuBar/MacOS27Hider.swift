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
    private var pending: MenuBarAssessmentAssertion?

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

    func restrict(to bundleIDs: [String]) {
        guard let classes, bundleIDs != allowed else { return }
        let allocated = (classes.configuration as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        guard let configuration = allocated?
            .perform(Self.configurationSelector, with: systemItems,
                     with: bundleIDs as NSArray)?.takeRetainedValue() else { return }

        pending?.invalidate()
        let assertion = unsafeBitCast(classes.assertion.init(),
                                      to: MenuBarAssessmentAssertion.self)
        pending = assertion
        assertion.activate(with: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending === assertion else { return }
                self.pending = nil
                if let error {
                    assertion.invalidate()
                    Log.menuBar.error("macOS 27 hiding failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.active?.assertion.invalidate()
                    self.active = (assertion, bundleIDs)
                }
            }
        }
    }

    func release() {
        pending?.invalidate()
        pending = nil
        active?.assertion.invalidate()
        active = nil
    }
}

@MainActor
final class MacOS27Hider {
    private static let alwaysAllowed: Set<String> = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent",
        "com.apple.systemuiserver", "com.apple.TextInputMenuAgent",
        "com.apple.Siri", "com.apple.Spotlight", "com.apple.wifi.WiFiAgent",
        "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.flux.menubar",
    ]

    private let assessment = MenuBarAssessment()
    private var hidden = Set<String>()
    private var alwaysHidden = Set<String>()
    private var revealHidden = false
    private var revealAlwaysHidden = false
    private var chevronX: CGFloat?
    private var alwaysX: CGFloat?
    private var generation = 0
    private var overClock = false
    private var mouseMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var clockFrameCache: (frame: CGRect, date: Date)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.reconcile()
            })
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] _ in self?.updateClockHover()
        }
    }

    var isAvailable: Bool { assessment.isAvailable }

    static func hiddenBundleIDs(_ positions: [(bundleID: String, x: CGFloat)],
                                leftOf boundary: CGFloat?) -> Set<String> {
        guard let boundary else { return [] }
        let groups = Dictionary(grouping: positions) { $0.bundleID }
        return Set(groups.compactMap { id, items in
            items.allSatisfy { $0.x < boundary } ? id : nil
        })
    }

    func apply(revealHidden: Bool, revealAlwaysHidden: Bool,
               chevronX: CGFloat?, alwaysX: CGFloat?) {
        self.revealHidden = revealHidden
        self.revealAlwaysHidden = revealAlwaysHidden
        self.chevronX = chevronX
        self.alwaysX = alwaysX
        retry()
    }

    func retry() {
        generation += 1
        let current = generation
        // Release before scanning: otherwise the hidden apps have no AX items.
        assessment.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == current else { return }
            guard self.assessment.isAvailable, AXIsProcessTrusted(),
                  let chevronX = self.chevronX else { return }
            let positions = Self.scanPositions()
            self.hidden = Self.hiddenBundleIDs(positions, leftOf: chevronX)
            self.alwaysHidden = Self.hiddenBundleIDs(positions, leftOf: self.alwaysX)
            self.reconcile()
        }
    }

    private func reconcile() {
        guard assessment.isAvailable, AXIsProcessTrusted(), !overClock else {
            assessment.release()
            return
        }
        let excluded = revealAlwaysHidden ? Set<String>()
            : (revealHidden ? alwaysHidden : hidden)
        guard !excluded.isEmpty else {
            assessment.release()
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let allowed = running.subtracting(excluded)
            .union(Self.alwaysAllowed).sorted()
        assessment.restrict(to: allowed)
    }

    /// Each app owns its AXExtrasMenuBar on macOS 27. One app can expose more
    /// than one icon; an icon in Shown keeps that whole app on the allow list.
    private static func scanPositions() -> [(bundleID: String, x: CGFloat)] {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app
            -> (pid: pid_t, id: String)? in
            guard let id = app.bundleIdentifier,
                  !id.hasPrefix("com.apple."),
                  !alwaysAllowed.contains(id),
                  app.activationPolicy != .prohibited else { return nil }
            return (app.processIdentifier, id)
        }
        let lock = NSLock()
        var result: [(bundleID: String, x: CGFloat)] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let app = AXUIElementCreateApplication(apps[index].pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString,
                                                &barValue) == .success,
                  let bar = barValue as? AXUIElement else { return }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString,
                                                &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { return }
            for child in children {
                var positionValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                    &positionValue) == .success,
                      let value = positionValue as? AXValue else { continue }
                var point = CGPoint.zero
                guard AXValueGetValue(value, .cgPoint, &point) else { continue }
                lock.lock()
                result.append((apps[index].id, point.x))
                lock.unlock()
            }
        }
        return result
    }

    // Assessment mode also blocks Notification Center. Lift the rule while
    // the pointer is on the clock, then restore it as soon as the pointer leaves.
    private func updateClockHover() {
        let point = NSEvent.mouseLocation
        let inMenuBar = NSScreen.screens.contains {
            $0.frame.contains(point) && point.y >= $0.frame.maxY - $0.menuBarThickness
        }
        let next = inMenuBar && clockFrame()?.contains(point) == true
        guard next != overClock else { return }
        overClock = next
        reconcile()
    }

    private func clockFrame() -> CGRect? {
        if let cached = clockFrameCache,
           Date().timeIntervalSince(cached.date) < 2 { return cached.frame }
        guard let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString,
                                            &barValue) == .success,
              let bar = barValue as? AXUIElement else { return nil }
        var groupsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString,
                                            &groupsValue) == .success,
              let groups = groupsValue as? [AXUIElement] else { return nil }
        for group in groups {
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString,
                                                &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            for child in children {
                var idValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString,
                                                    &idValue) == .success,
                      idValue as? String == "com.apple.menuextra.clock" else { continue }
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                    &positionValue) == .success,
                      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString,
                                                    &sizeValue) == .success,
                      let position = positionValue as? AXValue,
                      let size = sizeValue as? AXValue else { return nil }
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
