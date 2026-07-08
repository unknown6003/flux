import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey (⌥⌘B) to toggle reveal. Carbon's
/// `RegisterEventHotKey` is still the canonical, dependency-free way to get a
/// system-wide hotkey and works through Tahoe. Custom key recording is a
/// post-MVP refinement; the engine below already supports re-registration.
@MainActor
final class HotkeyManager {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register() {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            // The Carbon callback fires on the main run loop; hop onto the main
            // actor explicitly to satisfy isolation and keep AppKit calls safe.
            DispatchQueue.main.async {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onTrigger?()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x464C5558) /* 'FLUX' */, id: 1)
        let modifiers = UInt32(optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            Log.hotkey.info("Registered global hotkey ⌥⌘B")
        } else {
            Log.hotkey.error("Failed to register hotkey (OSStatus \(status))")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
