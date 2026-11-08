import AppKit
import ApplicationServices

@MainActor
final class MenuBarNativeDrag {
    private(set) var isRunning = false

    func perform(from frame: CGRect, to target: CGPoint,
                 canContinue: @escaping @MainActor () -> Bool) async -> Bool {
        guard !isRunning, canContinue(), CGPreflightPostEventAccess(),
              frame.width > 0, frame.height > 0,
              frame.midX.isFinite, frame.midY.isFinite,
              target.x.isFinite, target.y.isFinite,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let source = CGEventSource(stateID: .privateState) else { return false }
        isRunning = true
        let origin = CGEvent(source: nil)?.location ?? target
        var physicalFlags = CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn])
        var interrupted = false
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .rightMouseDown, .keyDown, .flagsChanged]) { event in
                MainActor.assumeIsolated {
                    guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
                    if event.type == .flagsChanged { physicalFlags = event.cgEvent?.flags ?? physicalFlags }
                    interrupted = true
                }
            }
        func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            return true
        }
        var pressed = false
        var lastPoint = CGPoint(x: frame.midX, y: frame.midY)
        defer {
            if pressed { _ = post(.leftMouseUp, at: lastPoint, flags: physicalFlags.union(.maskCommand)) }
            // Mouse flags must return to the user's state. A key-up would also
            // release a Command key that the user may be holding.
            let restore = interrupted || !canContinue() ? (CGEvent(source: nil)?.location ?? lastPoint) : origin
            _ = post(.mouseMoved, at: restore, flags: physicalFlags)
            if let monitor { NSEvent.removeMonitor(monitor) }
            isRunning = false
        }
        let flags = physicalFlags.union(.maskCommand)
        guard post(.leftMouseDown, at: lastPoint, flags: flags) else { return false }
        pressed = true
        let paced = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        if paced { try? await Task.sleep(nanoseconds: 60_000_000) }
        let start = lastPoint
        for step in 1...5 {
            guard !interrupted, canContinue() else { return false }
            let fraction = CGFloat(step) / 5
            lastPoint = CGPoint(x: start.x + (target.x - start.x) * fraction,
                                y: start.y + (target.y - start.y) * fraction)
            guard post(.leftMouseDragged, at: lastPoint, flags: flags) else { return false }
            try? await Task.sleep(nanoseconds: paced ? 120_000_000 : 18_000_000)
        }
        guard !interrupted, canContinue(), post(.leftMouseUp, at: target, flags: flags) else { return false }
        pressed = false
        return true
    }
}
