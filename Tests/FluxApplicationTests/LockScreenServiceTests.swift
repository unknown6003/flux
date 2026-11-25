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

    @Test @MainActor func emptyLockCardCannotTakeInputAndLockAndUnlockSoundsFireOnce() async throws {
        _ = NSApplication.shared
        var faded: [NSWindow] = []
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        let screen = try #require(NSScreen.screens.first)
        let bridge = FixtureLockBridge()
        var lockSounds = 0
        var unlockSounds = 0
        let service = NativeLockScreenService(preferences: preferences, availability: { .available },
            makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
            lockSound: { lockSounds += 1 }, unlockSound: { unlockSounds += 1 })
        let handle = try service.makeHandle()
        defer { handle.stop() }
        service.setPhase(.unlocked)
        #expect(lockSounds == 0)
        service.setPhase(.locked)
        service.setPhase(.locked)
        #expect(lockSounds == 1)
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
        // Now deliver live media while locked and verify the interactive card appears and fades to alpha == 1.
        var parser = MediaStream()
        let line = #"{"type":"data","diff":false,"payload":{"title":"Sweet Relief","artist":"Madison Beer","playing":true,"duration":162,"elapsedTime":107}}"# + "\n"
        let playing = try #require(try parser.append(Data(line.utf8)).compactMap { $0 }.first)
        service.receive(.media(.ready(playing)))
        let cardDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var foundCard: NSWindow?
        while ContinuousClock.now < cardDeadline {
            foundCard = NSApp.windows.first { $0.contentViewController is LockScreenContentController && $0.isVisible }
            if let card = foundCard, card.alphaValue >= 0.99 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let visibleCard = try #require(foundCard)
        #expect(!visibleCard.ignoresMouseEvents)
        #expect(visibleCard.alphaValue >= 0.99)
        service.setPhase(.unlocked)
        service.setPhase(.unlocked)
        #expect(bridge.detaches == 1)
        #expect(unlockSounds == 1)
        faded = windows + [visibleCard]
        handle.stop()
        #expect(bridge.detaches == 1)
        // The fade out takes 0.25 s before the windows close.
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
        // Minimal full-screen backdrop mode places the compact Liquid Glass
        // player lower (centered at 19.8%, never below 12.4%), cleanly above
        // the bottom unlock hint.
        let minimalFloorY = LockScreenWidgetPosition.originY(screenFrame: screen, notchHeight: 32, widgetHeight: 148,
                                                             hasMedia: true, minimalBackdrop: true)
        #expect(abs(minimalFloorY - (982 * 0.124)) < 0.01)
        let minimalCenteredY = LockScreenWidgetPosition.originY(screenFrame: tall, notchHeight: 32, widgetHeight: 148,
                                                                hasMedia: true, minimalBackdrop: true)
        #expect(abs(minimalCenteredY - (2000 * 0.198 - 74)) < 0.01)
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

    @Test @MainActor func transientNilMediaDuringTrackSwitchDoesNotHideThePlayerCard() async throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        let screen = try #require(NSScreen.screens.first)
        let bridge = FixtureLockBridge()
        let service = NativeLockScreenService(preferences: preferences, availability: { .available },
            makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
            mediaClearGracePeriod: .milliseconds(220))
        let handle = try service.makeHandle()
        defer { handle.stop() }
        service.setPhase(.locked)

        var parser = MediaStream()
        let trackA = #"{"type":"data","diff":false,"payload":{"title":"Track A","artist":"Artist","playing":true,"duration":180,"elapsedTime":40}}"# + "\n"
        let snapA = try #require(try parser.append(Data(trackA.utf8)).compactMap { $0 }.first)
        service.receive(.media(.ready(snapA)))

        let cardA = try #require(NSApp.windows.first { $0.contentViewController is LockScreenContentController && $0.isVisible })
        // Browser drops metadata between tracks -> card must stay mounted during grace period!
        service.receive(.media(.ready(nil)))
        try await Task.sleep(for: .milliseconds(80))
        #expect(cardA.isVisible)

        // Next track arrives before grace period expires -> same card stays visible without disappearing.
        let trackB = #"{"type":"data","diff":false,"payload":{"title":"Track B","artist":"Artist","playing":true,"duration":210,"elapsedTime":1}}"# + "\n"
        let snapB = try #require(try parser.append(Data(trackB.utf8)).compactMap { $0 }.first)
        service.receive(.media(.ready(snapB)))
        try await Task.sleep(for: .milliseconds(260))
        #expect(cardA.isVisible)

        // Real stop (nil persists past grace period) eventually dismisses the card.
        service.receive(.media(.ready(nil)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while cardA.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!cardA.isVisible)
    }

    @Test @MainActor func playActionTriggersMediaKeyFallbackOnlyWhenPlaybackStaysPaused() async throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        let screen = try #require(NSScreen.screens.first)
        let bridge = FixtureLockBridge()
        var fallbackCount = 0
        var sentActions: [LockScreenTransportAction] = []
        let service = NativeLockScreenService(preferences: preferences, availability: { .available },
            makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
            playFallback: { fallbackCount += 1 },
            playFallbackDelay: .milliseconds(120))
        service.onTransport = { sentActions.append($0) }
        let handle = try service.makeHandle()
        defer { handle.stop() }
        service.setPhase(.locked)

        var parser = MediaStream()
        let pausedLine = #"{"type":"data","diff":false,"payload":{"title":"Paused Track","artist":"Browser","playing":false,"duration":180,"elapsedTime":15}}"# + "\n"
        let paused = try #require(try parser.append(Data(pausedLine.utf8)).compactMap { $0 }.first)
        service.receive(.media(.ready(paused)))

        // Case 1: Play command succeeds before fallback delay -> fallback must NOT fire.
        service.handleTransport(.play)
        #expect(sentActions == [.play])
        let playingLine = #"{"type":"data","diff":false,"payload":{"title":"Paused Track","artist":"Browser","playing":true,"duration":180,"elapsedTime":16}}"# + "\n"
        let playing = try #require(try parser.append(Data(playingLine.utf8)).compactMap { $0 }.first)
        service.receive(.media(.ready(playing)))
        try await Task.sleep(for: .milliseconds(180))
        #expect(fallbackCount == 0)

        // Case 2: Track stays paused -> hardware media key fallback fires once.
        service.receive(.media(.ready(paused)))
        service.handleTransport(.play)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fallbackCount == 1)
    }

    @Test @MainActor func wallpaperPrecomposesWhileUnlockedWithoutCreatingABridge() async throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        try preferences.set(false, for: Preferences.lockScreenDepthEffect)

        // Write a tiny temporary PNG wallpaper file.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("flux-prewarm-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: tempURL)

        let screen = try #require(NSScreen.screens.first)
        var bridgeCreations = 0
        let bridge = FixtureLockBridge()
        let service = NativeLockScreenService(preferences: preferences, availability: { .available },
            makeBridge: { bridgeCreations += 1; return bridge },
            geometry: { fixtureGeometry(screen) },
            loadWallpaperURL: { tempURL })
        service.setPhase(.unlocked)
        let handle = try service.makeHandle()
        defer { handle.stop() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while service.composedBackdrop == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.composedBackdrop != nil)
        #expect(bridgeCreations == 0)
    }

    @Test @MainActor func immediateStopClosesAlreadyFadingLockWindowsWithoutWaitingForFadeOut() throws {
        _ = NSApplication.shared
        try profile { preferences in
            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
                lockSound: {}, unlockSound: {})
            let handle = try service.makeHandle()
            service.setPhase(.unlocked)
            service.setPhase(.locked)
            let ids = try #require(bridge.attached.first)
            let windows = NSApp.windows.filter { window in
                CGWindowID(exactly: window.windowNumber).map { ids.contains($0) } ?? false
            }
            #expect(!windows.isEmpty)
            // Animated unlock starts the 0.25s fade-out.
            service.setPhase(.unlocked)
            // A redundant animated unlock must not snap the in-flight fade closed.
            service.setPhase(.unlocked)
            #expect(windows.contains { $0.isVisible })
            // Immediate stop (e.g. sleep/quit) must close the fading windows synchronously.
            handle.stop()
            #expect(windows.allSatisfy { !$0.isVisible })
        }
    }
}
