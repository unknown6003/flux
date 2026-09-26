import AppKit
import ApplicationServices
import Combine
import CoreGraphics

enum SoundKey: Equatable {
    case volumeUp
    case volumeDown
    case mute
}

enum SoundKeyEvent: Equatable {
    case key(SoundKey, isRepeat: Bool, fine: Bool)
}

/// Consumes the system volume and mute keys so Flux's notch visualizer replaces
/// Apple's bezel. It quietly falls back to observe-only mode when Accessibility
/// is not granted.
@MainActor
final class MediaKeyInterceptor {
    let events = PassthroughSubject<SoundKeyEvent, Never>()
    var volumeControllable: () -> Bool = { true }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        // Permission prompts belong to the explicit Settings action. Starting the
        // sound HUD must never nag on launch or every time the notch appears.
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = 1 << 14
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    interceptor.handle(type: type, event: event)
                }
            },
            userInfo: context) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(event)
        }
        let parsed = Self.parse(data1: nsEvent.data1)
        guard let key = Self.key(for: parsed.keyCode),
              Self.shouldSwallow(key, volumeControllable: volumeControllable()) else {
            return Unmanaged.passRetained(event)
        }
        if parsed.keyDown {
            let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
            let soundEvent = SoundKeyEvent.key(key, isRepeat: parsed.isRepeat, fine: fine)
            Task { @MainActor [weak self] in self?.events.send(soundEvent) }
        }
        return nil
    }

    static func parse(data1: Int) -> (keyCode: Int, keyDown: Bool, isRepeat: Bool) {
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let flags = data1 & 0xFFFF
        return (keyCode, (flags & 0xFF00) >> 8 == 0xA, flags & 1 != 0)
    }

    static func key(for code: Int) -> SoundKey? {
        switch code {
        case 0: return .volumeUp
        case 1: return .volumeDown
        case 7: return .mute
        default: return nil
        }
    }

    static func shouldSwallow(_ key: SoundKey, volumeControllable: Bool) -> Bool {
        _ = key
        return volumeControllable
    }

    deinit {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
