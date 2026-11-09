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
        let saved = CGEvent(source: nil)?.location
        let hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            if let saved { CGWarpMouseCursorPosition(saved) }
            CGAssociateMouseAndMouseCursorPosition(1)
            if hidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try post(from: start, to: end) })
            }
        }
    }

    private static func post(from start: CGPoint, to end: CGPoint) throws {
        func event(_ type: CGEventType, _ point: CGPoint, command: Bool) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw MenuBarItemDragError.eventsUnavailable
            }
            if command { event.flags = .maskCommand }
            return event
        }
        let move = try event(.mouseMoved, start, command: false)
        let down = try event(.leftMouseDown, start, command: true)
        let up = try event(.leftMouseUp, end, command: true)
        // Make every event before posting any, so a mouse-down always gets its mouse-up.
        let drags = try (1...5).map { step in
            let progress = CGFloat(step) / 5
            return try event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress,
                                                        y: start.y + (end.y - start.y) * progress), command: true)
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        for drag in drags {
            drag.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.12)
        }
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
    }
}
