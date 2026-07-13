import AppKit
import Carbon.HIToolbox

/// Registers a single, user-configurable global hotkey to toggle reveal. Carbon's
/// `RegisterEventHotKey` is still the canonical, dependency-free way to get a
/// system-wide hotkey and works through Tahoe.
@MainActor
final class HotkeyManager {
    var onTrigger: (() -> Void)?

    /// The shortcut most recently handed to `register`. Kept so `isRegistered` and
    /// the Settings conflict hint can reflect what's actually live in the system.
    private(set) var registered: HotkeyShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Install `shortcut` as the global hotkey, replacing any previous one.
    ///
    /// Returns `false` when macOS refuses the registration — which in practice means
    /// **another app already owns that chord**. `RegisterEventHotKey` is first-come,
    /// first-served, so this is the only way to detect a conflict; Settings surfaces
    /// it so the user can pick a different chord instead of wondering why their
    /// hotkey silently does nothing.
    @discardableResult
    func register(_ shortcut: HotkeyShortcut) -> Bool {
        unregister()
        guard shortcut.isValid else {
            Log.hotkey.error("Refusing to register a modifier-less hotkey")
            return false
        }

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
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Log.hotkey.error("Failed to register hotkey \(shortcut.displayString, privacy: .public) (OSStatus \(status)) — likely already taken by another app")
            unregister()
            return false
        }
        registered = shortcut
        Log.hotkey.info("Registered global hotkey \(shortcut.displayString, privacy: .public)")
        return true
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
        registered = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
