import AppKit
import Carbon.HIToolbox

/// Registers user-configurable global hotkeys to toggle reveal. Carbon's
/// `RegisterEventHotKey` is still the canonical, dependency-free way to get a
/// system-wide hotkey and works through Tahoe.
///
/// Generalized to N independent registrations (menu-bar toggle, notch
/// toggle, ...) keyed by `HotkeyID`, sharing a single Carbon event handler:
/// `RegisterEventHotKey` hands every hotkey-pressed event to whichever
/// handler is installed for `kEventClassKeyboard`/`kEventHotKeyPressed`
/// regardless of which chord fired, so the one shared handler reads the
/// `EventHotKeyID` back off the event to know which registration it was.
@MainActor
final class HotkeyManager {
    /// Which global hotkey a registration is for. The raw value doubles as
    /// the Carbon `EventHotKeyID.id` so the shared event handler can map an
    /// incoming event straight back to an id with no side table.
    enum HotkeyID: UInt32 {
        case menuBarToggle = 1
        case notchToggle = 2
    }

    /// Fired when the matching registered hotkey is pressed. Keyed per-id so
    /// each caller only ever hears about the hotkey it owns; an id with no
    /// entry here simply does nothing when pressed.
    var onTrigger: [HotkeyID: () -> Void] = [:]

    private struct Registration {
        var hotKeyRef: EventHotKeyRef
        var shortcut: HotkeyShortcut
    }

    private var registrations: [HotkeyID: Registration] = [:]
    private var eventHandler: EventHandlerRef?

    private static let signature = OSType(0x464C_5558) // 'FLUX'

    /// The shortcut most recently registered for `id`, or `nil` if it isn't
    /// currently registered. Kept so Settings' per-hotkey conflict hint can
    /// reflect what's actually live in the system.
    func registered(_ id: HotkeyID) -> HotkeyShortcut? {
        registrations[id]?.shortcut
    }

    /// Install `shortcut` as `id`'s global hotkey, replacing any previous
    /// registration for that same id (other ids are untouched).
    ///
    /// Returns `false` when macOS refuses the registration — which in practice means
    /// **another app already owns that chord**. `RegisterEventHotKey` is first-come,
    /// first-served, so this is the only way to detect a conflict; Settings surfaces
    /// it so the user can pick a different chord instead of wondering why their
    /// hotkey silently does nothing.
    @discardableResult
    func register(_ shortcut: HotkeyShortcut, for id: HotkeyID) -> Bool {
        unregister(id)
        guard shortcut.isValid else {
            Log.hotkey.error("Refusing to register a modifier-less hotkey for \(String(describing: id))")
            return false
        }
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("Failed to register hotkey \(shortcut.displayString, privacy: .public) for \(String(describing: id), privacy: .public) (OSStatus \(status)) — likely already taken by another app")
            return false
        }
        registrations[id] = Registration(hotKeyRef: ref, shortcut: shortcut)
        Log.hotkey.info("Registered global hotkey \(shortcut.displayString, privacy: .public) for \(String(describing: id), privacy: .public)")
        return true
    }

    func unregister(_ id: HotkeyID) {
        guard let registration = registrations[id] else { return }
        UnregisterEventHotKey(registration.hotKeyRef)
        registrations[id] = nil
    }

    /// Tears down every registration and the shared event handler — used on
    /// deinit; not needed in normal operation since individual `unregister`
    /// calls handle settings changes.
    func unregisterAll() {
        for id in registrations.keys { unregister(id) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        for (_, registration) in registrations { UnregisterEventHotKey(registration.hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Shared event handler

    /// Installed once, lazily, on the first registration of any hotkey — every
    /// subsequent `RegisterEventHotKey` (for any id) is delivered through this
    /// same handler, which disambiguates by reading the event's own
    /// `EventHotKeyID` back out rather than needing one handler per chord.
    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr, let id = HotkeyID(rawValue: hotKeyID.id) else { return noErr }

            // The Carbon callback fires on the main run loop; hop onto the main
            // actor explicitly to satisfy isolation and keep AppKit calls safe.
            DispatchQueue.main.async {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onTrigger[id]?()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
    }
}
