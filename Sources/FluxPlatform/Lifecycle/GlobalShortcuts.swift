import Carbon.HIToolbox
import Foundation

public struct GlobalKeyChord: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let required = UInt32(cmdKey | optionKey | controlKey)
        return keyCode <= 127 && modifiers & ~allowed == 0 && modifiers & required != 0
    }
}

public enum GlobalShortcutError: Error { case invalidChord, unavailable(OSStatus) }

@MainActor public protocol GlobalKeyRegistering: AnyObject {
    func register(_ chord: GlobalKeyChord, action: @escaping @MainActor () -> Void) throws -> UInt32
    func remove(_ id: UInt32)
    func stop()
}

private struct ShortcutReference: @unchecked Sendable {
    // The pointer is immutable. Only main-actor Carbon calls consume it.
    let raw: EventHotKeyRef
}

/// Carbon routes registered chords without an Accessibility grant or a
/// keyboard monitor. One handler dispatches only this app's registered IDs.
@MainActor public final class GlobalShortcuts: GlobalKeyRegistering {
    private static let signature: OSType = 0x46584C58
    private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 0
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private var registrations: [UInt32: ShortcutReference] = [:]

    public init() {}

    deinit {
        let remaining = registrations
        Task { @MainActor in
            for (id, reference) in remaining {
                GlobalShortcuts.actions[id] = nil
                UnregisterEventHotKey(reference.raw)
            }
            GlobalShortcuts.removeEmptyHandler()
        }
    }

    @discardableResult
    public func register(_ chord: GlobalKeyChord, action: @escaping @MainActor () -> Void) throws -> UInt32 {
        guard chord.isValid else { throw GlobalShortcutError.invalidChord }
        try Self.installHandler()
        repeat { Self.nextID &+= 1 } while Self.nextID == 0 || Self.actions[Self.nextID] != nil
        let id = Self.nextID
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(chord.keyCode, chord.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: id),
                                        GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            Self.removeEmptyHandler()
            throw GlobalShortcutError.unavailable(result)
        }
        registrations[id] = ShortcutReference(raw: reference)
        Self.actions[id] = action
        return id
    }

    public func remove(_ id: UInt32) {
        guard let reference = registrations.removeValue(forKey: id) else { return }
        Self.actions[id] = nil
        UnregisterEventHotKey(reference.raw)
        Self.removeEmptyHandler()
    }

    public func stop() {
        for id in Array(registrations.keys) { remove(id) }
    }

    private static func installHandler() throws {
        guard handler == nil else { return }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x46584C58 else { return OSStatus(eventNotHandledErr) }
            let id = key.id
            Task { @MainActor in GlobalShortcuts.actions[id]?() }
            return noErr
        }, 1, &kind, nil, &handler)
        guard result == noErr else { throw GlobalShortcutError.unavailable(result) }
    }

    private static func removeEmptyHandler() {
        guard actions.isEmpty, let handler else { return }
        RemoveEventHandler(handler)
        Self.handler = nil
    }
}
