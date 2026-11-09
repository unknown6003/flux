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

@MainActor private func fixtureGeometry(_ screen: NSScreen) -> LockScreenGeometry {
    LockScreenGeometry(notch: CGRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 32, width: 180, height: 32),
                       screenFrame: screen.frame)
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

    @Test @MainActor func emptyLockCardCannotTakeInputAndUnlockReleasesItsWindowsOnce() async throws {
        _ = NSApplication.shared
        var faded: [NSWindow] = []
        try profile { preferences in
            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var sounds = 0
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) }, unlockSound: { sounds += 1 })
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
            faded = windows
            handle.stop()
            #expect(bridge.detaches == 1)
        }
        // The 0.21.35 fade out takes 0.25 s before the windows close.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while faded.contains(where: \.isVisible), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(faded.allSatisfy { !$0.isVisible })
    }

    @Test @MainActor func lockPillUsesTheOldCaptionRule() throws {
        let timer = try ActivityItem(kind: .timer, leading: .symbol("timer"), trailing: .text("4:31"), priority: 110, duration: nil)
        #expect(NativeLockScreenService.caption(timer) == .init(symbolName: "timer", text: "4:31"))
        let device = try ActivityItem(kind: .bluetoothDevice, leading: .symbol("airpodspro"),
                                      trailing: .symbolText(symbol: "battery.75", text: "80%"), priority: 100, duration: 4)
        #expect(NativeLockScreenService.caption(device) == .init(symbolName: "airpodspro", text: "80%"))
        let battery = try ActivityItem(kind: .battery, leading: .symbol("battery.0"), trailing: .text("9%"), priority: 200, duration: nil)
        #expect(NativeLockScreenService.caption(battery) == nil)
        let sound = try ActivityItem(kind: .soundHUD, leading: .none, trailing: .soundGauge(value: 0.5, symbol: "speaker.fill"),
                                     priority: 300, duration: 1.5)
        #expect(NativeLockScreenService.caption(sound) == nil)
        // Media card centered at 28% of the screen from the bottom, but never
        // below 20%; the caption alone centers at 21%.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(LockScreenWidgetPosition.originY(screenFrame: screen, notchHeight: 32, widgetHeight: 164, hasMedia: true)
                == 982 * 0.20)
        let tall = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        #expect(abs(LockScreenWidgetPosition.originY(screenFrame: tall, notchHeight: 32, widgetHeight: 100, hasMedia: true) - 510) < 0.001)
        #expect(LockScreenWidgetPosition.originY(screenFrame: screen, notchHeight: 32, widgetHeight: 38, hasMedia: false)
                == 982 * 0.21 - 19)
    }

    /// Loads SkyLight's private symbols on this Mac without locking the
    /// screen or making a space. On macOS 27 this must report available.
    @Test @MainActor func skyLightBridgeLoadsAndSettingsReportAvailable() throws {
        let loadable = SkyLightLockScreenSpace.isLoadable
        let version = ProcessInfo.processInfo.operatingSystemVersion
        print("skylight.lockscreen.loadable=\(loadable) macOS=\(version.majorVersion).\(version.minorVersion)")
        if version.majorVersion >= 27 { #expect(loadable) }
        try profile { preferences in
            let service = NativeLockScreenService(preferences: preferences)
            #expect(service.capability == (loadable ? .available : .unavailable))
            #expect(service.failureCode == nil)
        }
    }

    @Test @MainActor func failedDetachQuarantinesTheBridgeUntilAnExplicitRetry() throws {
        _ = NSApplication.shared
        try profile { preferences in
            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var created = 0
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { created += 1; return bridge }, geometry: { fixtureGeometry(screen) }, unlockSound: {})
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
