import FluxCore
import FluxPlatform
import FluxUI

/// Keeps the previous chord live until macOS accepts its replacement. Settings
/// owns saving; this owner only registers the two app actions and reports the
/// real registration result. No event monitor or Accessibility grant is used.
@MainActor public final class AppShortcuts {
    private struct Registration { let id: UInt32; let chord: GlobalKeyChord }
    private let preferences: PreferenceStore
    private let keys: any GlobalKeyRegistering
    private let reveal: @MainActor () -> Void
    private let notch: @MainActor () -> Void
    private var registrations: [ShortcutRole: Registration] = [:]
    private var conflicts: [ShortcutRole: ShortcutConflict] = [:]
    private var started = false

    public convenience init(preferences: PreferenceStore, reveal: @escaping @MainActor () -> Void,
                            notch: @escaping @MainActor () -> Void) {
        self.init(preferences: preferences, keys: GlobalShortcuts(), reveal: reveal, notch: notch)
    }
    init(preferences: PreferenceStore, keys: any GlobalKeyRegistering,
         reveal: @escaping @MainActor () -> Void, notch: @escaping @MainActor () -> Void) {
        self.preferences = preferences; self.keys = keys; self.reveal = reveal; self.notch = notch
    }

    public func start() { started = true; refresh() }
    public func stop() {
        started = false
        keys.stop(); registrations.removeAll(); conflicts.removeAll()
    }
    public func refresh() {
        guard started else { return }
        guard preferences.value(for: Preferences.enableHotkey) else {
            keys.stop(); registrations.removeAll(); conflicts.removeAll()
            return
        }
        let reveal = saved(.reveal), notch = saved(.notch)
        if reveal == notch {
            keys.stop(); registrations.removeAll()
            conflicts = [.reveal: .otherFluxShortcut, .notch: .otherFluxShortcut]
            return
        }
        for role in [ShortcutRole.reveal, .notch] {
            _ = replace(role, with: ui(saved(role)))
        }
    }

    public func conflict(_ role: ShortcutRole) -> ShortcutConflict {
        guard started, preferences.value(for: Preferences.enableHotkey) else { return .clear }
        return conflicts[role] ?? .unavailable
    }

    /// Called before Settings saves the new chord. A failed replacement does
    /// not remove the registration for the saved chord.
    @discardableResult public func replace(_ role: ShortcutRole, with shortcut: Shortcut) -> Bool {
        guard started, preferences.value(for: Preferences.enableHotkey) else { return false }
        let chord = GlobalKeyChord(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
        let other: ShortcutRole = role == .reveal ? .notch : .reveal
        guard chord.isValid else { conflicts[role] = .unavailable; return false }
        guard chord != registrations[other]?.chord else { conflicts[role] = .otherFluxShortcut; return false }
        if registrations[role]?.chord == chord { conflicts[role] = .clear; return true }
        do {
            let action = role == .reveal ? reveal : notch
            let id = try keys.register(chord, action: action)
            let old = registrations.updateValue(.init(id: id, chord: chord), forKey: role)
            if let old { keys.remove(old.id) }
            conflicts[role] = .clear
            return true
        } catch { conflicts[role] = .unavailable; return false }
    }

    private func saved(_ role: ShortcutRole) -> GlobalKeyChord {
        switch role {
        case .reveal: return .init(keyCode: preferences.value(for: Preferences.hotkeyKeyCode),
                                  modifiers: preferences.value(for: Preferences.hotkeyModifiers))
        case .notch: return .init(keyCode: preferences.value(for: Preferences.notchHotkeyKeyCode),
                                 modifiers: preferences.value(for: Preferences.notchHotkeyModifiers))
        }
    }
    private func ui(_ chord: GlobalKeyChord) -> Shortcut { .init(keyCode: chord.keyCode, carbonModifiers: chord.modifiers) }
}
