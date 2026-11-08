import AppKit
import ApplicationServices

@MainActor
final class MenuBarNativeDrag {
    private(set) var isRunning = false
    private(set) var hasPostedInput = false
    private(set) var diagnostics = "none"

    func perform(from frame: CGRect, to target: CGPoint,
                 expectedProcessID: pid_t? = nil,
                 expectedElement: AXUIElement? = nil,
                 canContinue: @escaping @MainActor () -> Bool) async -> Bool {
        diagnostics = "preflight"
        guard !isRunning, canContinue(), CGPreflightPostEventAccess(),
              frame.width > 0, frame.height > 0,
              frame.midX.isFinite, frame.midY.isFinite,
              target.x.isFinite, target.y.isFinite,
              Self.isInMenuBar(target),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let source = CGEventSource(stateID: .privateState) else {
            diagnostics = "input unavailable, held, cancelled, or outside the menu bar; source=\(frame), target=\(target)"
            return false
        }
        let points = [frame.midX, frame.minX + frame.width / 4, frame.maxX - frame.width / 4,
                      frame.minX + min(3, frame.width / 4), frame.maxX - min(3, frame.width / 4)]
            .map { CGPoint(x: $0, y: frame.midY) }.filter(Self.isInMenuBar)
        guard let center = points.first else {
            diagnostics = "source has no point in the menu bar; frame=\(frame)"
            return false
        }
        isRunning = true
        let origin = CGEvent(source: nil)?.location ?? target
        var physicalFlags = CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn])
        var interrupted = false
        let observe: (NSEvent) -> Void = { event in
                    guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
                    if event.type == .flagsChanged { physicalFlags = event.cgEvent?.flags ?? physicalFlags }
                    interrupted = true
                    self.diagnostics = "external input \(event.type.rawValue), pid=\(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1)"
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .rightMouseDown, .keyDown, .flagsChanged]
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { observe(event) }
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { observe(event) }
            return event
        }
        func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            return true
        }
        var pressed = false
        var postedInput = false
        var lastPoint = center
        defer {
            if pressed { _ = post(.leftMouseUp, at: lastPoint, flags: physicalFlags.union(.maskCommand)) }
            // Mouse flags must return to the user's state. A key-up would also
            // release a Command key that the user may be holding.
            if postedInput {
                let restore = interrupted || !canContinue() ? (CGEvent(source: nil)?.location ?? lastPoint) : origin
                _ = post(.mouseMoved, at: restore, flags: physicalFlags)
            }
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            hasPostedInput = false
            isRunning = false
        }
        if let expectedProcessID {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            let readyBy = ProcessInfo.processInfo.systemUptime + 3
            var selected: CGPoint?
            repeat {
                guard !interrupted, canContinue() else { return false }
                for point in points {
                    var hit: AXUIElement?
                    var hitPID: pid_t = 0
                    let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
                    var role: CFTypeRef?
                    if let hit {
                        _ = AXUIElementGetPid(hit, &hitPID)
                        AXUIElementSetMessagingTimeout(hit, 0.05)
                        _ = AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
                    }
                    diagnostics = "source hit owner=\(hitPID), role=\(role as? String ?? "unknown"), expected=\(expectedProcessID), point=\(point), frame=\(frame)"
                    guard error == .success, let hit, hitPID == expectedProcessID else { continue }
                    guard expectedElement.map({ Self.containsSource(hit, source: $0) }) ?? true else { continue }
                    selected = point
                    break
                }
                if selected != nil { break }
                guard ProcessInfo.processInfo.systemUptime < readyBy else { return false }
                try? await Task.sleep(nanoseconds: 150_000_000)
            } while true
            guard !interrupted, canContinue(), let selected else { return false }
            lastPoint = selected
        }
        let flags = physicalFlags.union(.maskCommand)
        guard post(.leftMouseDown, at: lastPoint, flags: flags) else {
            diagnostics = "could not create mouse-down"
            return false
        }
        pressed = true
        postedInput = true
        hasPostedInput = true
        let paced = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        if paced { try? await Task.sleep(nanoseconds: 60_000_000) }
        let start = lastPoint
        for step in 1...5 {
            guard !interrupted, canContinue() else {
                if !interrupted { diagnostics = "transaction cancelled at step \(step)" }
                return false
            }
            let fraction = CGFloat(step) / 5
            lastPoint = CGPoint(x: start.x + (target.x - start.x) * fraction,
                                y: start.y + (target.y - start.y) * fraction)
            guard post(.leftMouseDragged, at: lastPoint, flags: flags) else {
                diagnostics = "could not create drag step \(step)"
                return false
            }
            try? await Task.sleep(nanoseconds: paced ? 120_000_000 : 18_000_000)
        }
        guard !interrupted, canContinue(), post(.leftMouseUp, at: target, flags: flags) else {
            if !interrupted { diagnostics = "transaction cancelled before mouse-up" }
            return false
        }
        pressed = false
        diagnostics = "posted complete drag; source=\(frame), point=\(start), target=\(target)"
        return true
    }

    private static func containsSource(_ hit: AXUIElement, source: AXUIElement) -> Bool {
        var current = hit
        for _ in 0..<5 {
            if CFEqual(current, source) { return true }
            AXUIElementSetMessagingTimeout(current, 0.05)
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func isInMenuBar(_ point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let appKitPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return NSScreen.screens.contains { $0.statusItemRegion.contains(appKitPoint) }
    }
}
