import AppKit
import FluxCore

@MainActor enum VolumeTapCallbacks {
    static var next: UInt = 0
    static var actions: [UInt: @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?] = [:]
    static func dispatch(token: UInt, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let action = actions[token] else { return Unmanaged.passUnretained(event) }
        return action(type, event)
    }
}

// Only the synchronous C callback returns this value. It is never queued or
// moved to another thread; the run-loop source is bound to the main thread.
private struct VolumeTapReturn: @unchecked Sendable { let event: Unmanaged<CGEvent>? }

private final class VolumeTapRegistration: @unchecked Sendable {
    let tap: CFMachPort
    private let source: CFRunLoopSource
    private let token: UInt
    init(tap: CFMachPort, source: CFRunLoopSource, token: UInt) {
        self.tap = tap; self.source = source; self.token = token
    }
    deinit {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopSourceInvalidate(source)
        CFMachPortInvalidate(tap)
        let token = token
        Task { @MainActor in VolumeTapCallbacks.actions[token] = nil }
    }
}

/// An active filter for volume/mute packets only. It never reads text keys,
/// prompts for access, posts synthetic input or does audio I/O in the callback.
@MainActor public final class VolumeKeyTap {
    private let canControl: @MainActor () -> Bool
    private let keyDown: @MainActor (VolumeKey, Bool, Bool) -> Bool
    private var registration: VolumeTapRegistration?
    private var held: Set<VolumeKey> = []
    private var timeouts = 0

    public init(canControl: @escaping @MainActor () -> Bool,
                keyDown: @escaping @MainActor (VolumeKey, Bool, Bool) -> Bool) {
        self.canControl = canControl; self.keyDown = keyDown
    }
    public var isActive: Bool { registration.map { CGEvent.tapIsEnabled(tap: $0.tap) } ?? false }

    @discardableResult public func start() -> Bool {
        if registration != nil { return isActive }
        guard PermissionAccess.status(.accessibility) == .allowed, canControl() else { return false }
        repeat { VolumeTapCallbacks.next &+= 1 } while VolumeTapCallbacks.next == 0 || VolumeTapCallbacks.actions[VolumeTapCallbacks.next] != nil
        let token = VolumeTapCallbacks.next
        VolumeTapCallbacks.actions[token] = { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1) << 14,
            callback: { _, type, event, context in
                // The source is installed only on the main run loop.
                MainActor.assumeIsolated {
                    VolumeTapReturn(event: VolumeTapCallbacks.dispatch(token: UInt(bitPattern: context), type: type, event: event))
                }.event
            }, userInfo: UnsafeMutableRawPointer(bitPattern: token)) else {
            VolumeTapCallbacks.actions[token] = nil
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            VolumeTapCallbacks.actions[token] = nil
            return false
        }
        registration = VolumeTapRegistration(tap: tap, source: source, token: token)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        timeouts = 0
        CGEvent.tapEnable(tap: tap, enable: true)
        return isActive
    }

    public func stop() { held.removeAll(); registration = nil }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByUserInput { stop(); return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout {
            timeouts += 1
            if timeouts <= 3, let registration, PermissionAccess.status(.accessibility) == .allowed {
                CGEvent.tapEnable(tap: registration.tap, enable: true)
            } else { stop() }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, registration != nil,
              let packet = NSEvent(cgEvent: event), packet.subtype.rawValue == 8,
              let key = VolumeKeyPacket(data1: Int64(packet.data1)) else { return Unmanaged.passUnretained(event) }
        if !key.down { return held.remove(key.key) != nil ? nil : Unmanaged.passUnretained(event) }
        guard canControl() else { return Unmanaged.passUnretained(event) }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        guard keyDown(key.key, key.repeated, fine) else { return Unmanaged.passUnretained(event) }
        held.insert(key.key)
        return nil
    }
}
