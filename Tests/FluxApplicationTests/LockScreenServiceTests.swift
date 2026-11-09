import AppKit
import Testing
import FluxCore
import FluxUI
import FluxPlatform
@testable import FluxApplication

@MainActor private final class FixtureLockBridge: LockScreenWindowBridge {
    var attached: [[CGWindowID]] = []
    var detaches = 0
    var failDetach = false
    func attach(windowIDs: [CGWindowID]) { attached.append(windowIDs) }
    func detach() throws {
        detaches += 1
        if failDetach { throw LockScreenWindowError.cleanupPending }
    }
}

@Suite(.serialized) struct LockScreenServiceTests {
    @MainActor private func profile(_ body: (PreferenceStore) throws -> Void) throws {
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        try body(preferences)
    }

    @Test @MainActor func unsupportedOrUnlockedBackendNeverCreatesAPrivateBridge() throws {
        try profile { preferences in
            var created = 0
            let bridge = FixtureLockBridge()
            let unavailable = NativeLockScreenService(preferences: preferences, availability: { .unavailable },
                makeBridge: { created += 1; return bridge }, unlockSound: {})
            #expect(throws: LockScreenServiceError.unavailable) { try unavailable.makeHandle() }
            unavailable.setPhase(.locked)
            unavailable.stop()
            #expect(created == 0)
            let supported = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { created += 1; return bridge }, unlockSound: {})
            supported.setPhase(.unlocked)
            let handle = try supported.makeHandle()
            #expect(created == 0)
            handle.stop()
            #expect(bridge.attached.isEmpty)
        }
    }

    @Test @MainActor func emptyLockCardCannotTakeInputAndUnlockReleasesItsWindowsOnce() throws {
        _ = NSApplication.shared
        try profile { preferences in
            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var sounds = 0
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, screen: { screen }, unlockSound: { sounds += 1 })
            let handle = try service.makeHandle()
            defer { handle.stop() }
            service.setPhase(.locked)
            let ids = try #require(bridge.attached.first)
            let windows = NSApp.windows.filter { window in
                CGWindowID(exactly: window.windowNumber).map { ids.contains($0) } ?? false
            }
            #expect(!windows.isEmpty)
            for window in windows {
                #expect(window.ignoresMouseEvents)
                #expect(!window.isKeyWindow)
                if window.contentViewController is LockScreenContentController { #expect(!window.isVisible) }
            }
            service.setPhase(.unlocked)
            service.setPhase(.unlocked)
            #expect(bridge.detaches == 1)
            #expect(sounds == 1)
            #expect(windows.allSatisfy { !$0.isVisible })
            handle.stop()
            #expect(bridge.detaches == 1)
        }
    }

    @Test @MainActor func failedDetachQuarantinesTheBridgeUntilAnExplicitRetry() throws {
        _ = NSApplication.shared
        try profile { preferences in
            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var created = 0
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { created += 1; return bridge }, screen: { screen }, unlockSound: {})
            let handle = try service.makeHandle()
            defer { handle.stop() }
            service.setPhase(.locked)
            #expect(created == 1)
            bridge.failDetach = true
            service.setPhase(.unlocked)
            #expect(service.failureCode == "lock.cleanup")
            #expect(bridge.detaches == 1)
            service.setPhase(.locked)
            service.configure()
            service.receive(.media(.unavailable))
            #expect(created == 1)
            #expect(bridge.detaches == 1)
            bridge.failDetach = false
            service.checkAgain()
            #expect(service.failureCode == nil)
            #expect(created == 2)
            #expect(bridge.detaches == 2)
            handle.stop()
            #expect(bridge.detaches == 3)
        }
    }
}
