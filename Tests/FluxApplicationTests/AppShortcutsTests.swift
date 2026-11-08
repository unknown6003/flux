import Foundation
import Testing
import FluxCore
import FluxPlatform
import FluxUI
@testable import FluxApplication

@MainActor private final class KeyRegistrations: GlobalKeyRegistering {
    var held: [UInt32: GlobalKeyChord] = [:]
    var actions: [UInt32: @MainActor () -> Void] = [:]
    var unavailable: GlobalKeyChord?
    private var next: UInt32 = 0
    func register(_ chord: GlobalKeyChord, action: @escaping @MainActor () -> Void) throws -> UInt32 {
        if chord == unavailable { throw GlobalShortcutError.unavailable(-1) }
        next += 1
        held[next] = chord; actions[next] = action
        return next
    }
    func remove(_ id: UInt32) { held[id] = nil; actions[id] = nil }
    func stop() { held.removeAll(); actions.removeAll() }
}

@Test @MainActor func refusedShortcutKeepsThePreviousActionAndDisablingReleasesBoth() throws {
    let domain = "org.fluxfixture.shortcuts.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
    let keys = KeyRegistrations()
    var revealed = 0
    let owner = AppShortcuts(preferences: preferences, keys: keys, reveal: { revealed += 1 }, notch: {})
    defer { owner.stop() }
    #expect(keys.held.isEmpty)
    owner.start()
    let old = try #require(keys.held.first { $0.value.keyCode == 3 }?.key)
    #expect(keys.held.count == 2)
    let refused = GlobalKeyChord(keyCode: 4, modifiers: 6400)
    keys.unavailable = refused
    #expect(!owner.replace(.reveal, with: .init(keyCode: 4, carbonModifiers: 6400)))
    #expect(keys.held[old]?.keyCode == 3)
    keys.actions[old]?()
    #expect(revealed == 1)
    #expect(owner.conflict(.reveal) == .clear)
    keys.unavailable = nil
    #expect(owner.replace(.reveal, with: .init(keyCode: 4, carbonModifiers: 6400)))
    #expect(keys.held[old] == nil)
    #expect(keys.held.count == 2)
    #expect(owner.conflict(.reveal) == .clear)
    #expect(preferences.value(for: Preferences.hotkeyKeyCode) == 3)
    try preferences.set(false, for: Preferences.enableHotkey)
    owner.refresh()
    #expect(keys.held.isEmpty)
    #expect(owner.conflict(.reveal) == .clear)
}
