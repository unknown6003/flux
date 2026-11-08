import Foundation
import Testing
@testable import FluxCore

@Test func migrationPreservesLiteralLegacyChoicesAndUnownedFields() throws {
    let fixture: [String: Any] = [
        "flux.launchAtLogin": true,
        "flux.showAlwaysHiddenSection": false,
        "flux.autoRehide": false,
        "flux.autoRehideDelay": 14.5,
        "flux.enableHotkey": false,
        "flux.automaticUpdateChecks": false,
        "flux.appearance": "light",
        "flux.iconStyle": "line",
        "flux.hotkey.keyCode": 8,
        "flux.hotkey.modifiers": 256,
        "flux.notch.enabled": false,
        "flux.notch.expansionTrigger": "click",
        "flux.notch.hoverCloseDelay": 0.75,
        "flux.notch.showInFullscreen": false,
        "flux.notch.widgetOrder": ["calendar", "future-widget", "shelf"],
        "flux.notch.nowPlayingEnabled": false,
        "flux.notch.shelf.enabled": false,
        "flux.notch.shelf.expiryDays": 7.0,
        "flux.notch.calendar.enabled": false,
        "flux.notch.activities.battery": false,
        "flux.notch.activities.bluetooth": false,
        "flux.notch.activities.calendarEvent": false,
        "flux.notch.duo": true,
        "flux.notch.mirror.enabled": false,
        "flux.notch.clipboard.enabled": true,
        "flux.notch.clipboard.persistence.enabled": false,
        "flux.notch.activities.timer": false,
        "flux.notch.activities.soundHUD": false,
        "flux.notch.lockScreenExperiment": true,
        "flux.notch.lockScreen.nowPlaying": false,
        "flux.notch.lockScreen.activities": false,
        "flux.notch.lockScreen.unlockSound": false,
        "flux.notch.hotkey.keyCode": 46,
        "flux.notch.hotkey.modifiers": 512,
        "flux.macOS27IconLayout": ["hidden": ["com.example.App"], "alwaysHidden": []],
        "NSStatusItem Preferred Position flux.chevron.v27": 142,
        "flux.future.setting": ["opaque": "keep"]
    ]
    let plan = PreferenceMigration(persisted: fixture, evidence: InstallationEvidence())
    #expect(plan.origin == .upgrade)
    #expect(plan.missingValues.isEmpty)
    #expect(Preferences.registrations.count == 34)
    #expect(Preferences.widgetOrder.value(from: fixture["flux.notch.widgetOrder"]) == ["calendar", "future-widget", "shelf"])
    #expect(Preferences.hotkeyKeyCode.value(from: fixture["flux.hotkey.keyCode"]) == 8)
    #expect(Preferences.appearance.value(from: fixture["flux.appearance"]) == .light)
}

@Test func oldImplicitDefaultsRemainEnabledEvenWithNoExplicitFeatureSwitches() {
    let evidence: [InstallationEvidence] = [
        InstallationEvidence(hasExistingData: true),
        InstallationEvidence(isUpdateLaunch: true)
    ]
    for source in evidence {
        let migration = PreferenceMigration(persisted: [:], evidence: source)
        #expect(migration.origin == .upgrade)
        #expect(migration.missingValues["flux.notch.clipboard.enabled"] as? Bool == true)
        #expect(migration.missingValues["flux.notch.clipboard.persistence.enabled"] as? Bool == true)
        #expect(migration.missingValues["flux.notch.lockScreenExperiment"] as? Bool == true)
    }
    for key in ["flux.layoutVersion", "NSStatusItem Preferred Position flux.chevron"] {
        let migration = PreferenceMigration(persisted: [key: 5], evidence: InstallationEvidence())
        #expect(migration.origin == .upgrade)
    }
}

@Test @MainActor func migrationWritesOnlyMissingSettingsAndKeepsTheNewProfileOriginOnRetry() throws {
    let suite = "flux-preferences-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PreferenceStore(defaults: defaults, domain: suite, evidence: InstallationEvidence())
    #expect(store.origin == .new)
    #expect(!store.value(for: Preferences.clipboardEnabled))
    #expect(!store.value(for: Preferences.clipboardPersistenceEnabled))
    #expect(!store.value(for: Preferences.lockScreenEnabled))
    #expect(store.value(for: Preferences.nowPlayingEnabled))
    try store.set(true, for: Preferences.clipboardEnabled)
    defaults.set(["opaque": "keep"], forKey: "flux.future.setting")
    defaults.set(142, forKey: "NSStatusItem Preferred Position flux.chevron.v27")
    // Model a first launch stopped before all defaults were written.
    defaults.removeObject(forKey: "flux.notch.lockScreenExperiment")
    let reopened = PreferenceStore(defaults: defaults, domain: suite, evidence: InstallationEvidence(hasExistingData: true))
    #expect(reopened.origin == .new)
    #expect(reopened.value(for: Preferences.clipboardEnabled))
    #expect(!reopened.value(for: Preferences.lockScreenEnabled))
    #expect(defaults.dictionary(forKey: "flux.future.setting") as? [String: String] == ["opaque": "keep"])
    #expect(defaults.integer(forKey: "NSStatusItem Preferred Position flux.chevron.v27") == 142)
}

@Test @MainActor func malformedPreferencesStayOnDiskButCannotEnablePrivateFeatures() throws {
    let suite = "flux-preferences-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("yes", forKey: "flux.notch.clipboard.enabled")
    defaults.set(1, forKey: "flux.notch.lockScreenExperiment")
    defaults.set(-1, forKey: "flux.hotkey.keyCode")
    defaults.set("future-mode", forKey: "flux.appearance")
    let store = PreferenceStore(defaults: defaults, domain: suite, evidence: InstallationEvidence())
    #expect(store.origin == .upgrade)
    #expect(!store.value(for: Preferences.clipboardEnabled))
    #expect(!store.value(for: Preferences.lockScreenEnabled))
    #expect(store.value(for: Preferences.hotkeyKeyCode) == 3)
    #expect(store.value(for: Preferences.appearance) == .dark)
    #expect(defaults.string(forKey: "flux.notch.clipboard.enabled") == "yes")
    #expect(defaults.string(forKey: "flux.appearance") == "future-mode")
    #expect(throws: PreferenceError.self) { try store.set(.nan, for: Preferences.autoRehideDelay) }
    #expect(throws: PreferenceError.self) { try store.set(-1, for: Preferences.shelfExpiryDays) }
    #expect(Preferences.autoRehideDelay.value(from: true) == nil)
    #expect(Preferences.hotkeyModifiers.value(from: 3.5) == nil)
    #expect(Preferences.hotkeyModifiers.value(from: Double(UInt32.max) + 1) == nil)
}
