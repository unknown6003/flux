import AppKit
import CoreGraphics

public enum MenuBarItemDragError: Error, Sendable {
    case eventsUnavailable, inputBusy
}

/// Posts one Cmd-drag of a status item, then puts the pointer back.
///
/// macOS 27's MenuBarAgent drops fast synthetic drags. Flux 0.21.35 proved
/// this pace on a real macOS 27 runner: a 60 ms pause after mouse-down and
/// five drag steps 120 ms apart. Ice, Thaw and Bartender use the same kind of
/// Cmd-drag. Posting runs off the main thread, so the UI keeps drawing.
public enum MenuBarItemDrag {
    private static let queue = DispatchQueue(label: "com.flux.menubar.item-drag", qos: .userInitiated)

    /// No mouse button and no modifier key is down.
    public static func inputIsQuiet() -> Bool {
        let buttons = [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return !buttons && CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
    }

    /// Points are Quartz global coordinates (top-left origin).
    @MainActor public static func perform(from start: CGPoint, to end: CGPoint) async throws {
        guard inputIsQuiet() else { throw MenuBarItemDragError.inputBusy }
        let modifiers = DragModifierState(initial: CGEventSource.flagsState(.combinedSessionState))
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            modifiers.record(event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        }) else { throw MenuBarItemDragError.eventsUnavailable }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            modifiers.record(event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            return event
        }) else {
            NSEvent.removeMonitor(global)
            throw MenuBarItemDragError.eventsUnavailable
        }
        defer { NSEvent.removeMonitor(local); NSEvent.removeMonitor(global) }
        let saved = CGEvent(source: nil)?.location
        let hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
            if hidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try post(from: start, to: end, modifiers: modifiers) })
            }
        }
    }

    private static func post(from start: CGPoint, to end: CGPoint, modifiers: DragModifierState) throws {
        guard inputIsQuiet() else { throw MenuBarItemDragError.inputBusy }
        func event(_ type: CGEventType, _ point: CGPoint, command: Bool) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw MenuBarItemDragError.eventsUnavailable
            }
            event.flags = modifiers.flags.union(command ? .maskCommand : [])
            return event
        }
        let move = try event(.mouseMoved, start, command: false)
        let down = try event(.leftMouseDown, start, command: true)
        let up = try event(.leftMouseUp, end, command: true)
        let release = try event(.mouseMoved, end, command: false)
        // Make every event before posting any, so a mouse-down always gets its mouse-up.
        let drags = try (1...5).map { step in
            let progress = CGFloat(step) / 5
            return try event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress,
                                                        y: start.y + (end.y - start.y) * progress), command: true)
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.flags = modifiers.flags.union(.maskCommand)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        for drag in drags {
            drag.flags = modifiers.flags.union(.maskCommand)
            drag.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.12)
        }
        up.flags = modifiers.flags.union(.maskCommand)
        up.post(tap: .cghidEventTap)
        // The Command mouse-up leaves Command in the shared input state on
        // macOS 27. Restore actual keyboard flags, including changes during
        // the drag, without posting any keyboard event.
        release.flags = modifiers.flags
        release.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
    }
}

/// Only real keyboard flag events update this state. Posted mouse flags must
/// not become the keyboard state restored at the end of Flux's drag.
private final class DragModifierState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CGEventFlags
    init(initial: CGEventFlags) { value = initial }
    var flags: CGEventFlags { lock.withLock { value } }
    func record(_ flags: CGEventFlags) { lock.withLock { value = flags } }
}
