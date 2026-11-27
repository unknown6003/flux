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

    @MainActor private func asyncProfile(_ body: (PreferenceStore) async throws -> Void) async throws {
        let domain = "org.fluxfixture.lock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.notchEnabled)
        try preferences.set(true, for: Preferences.lockScreenEnabled)
        try await body(preferences)
    }

    @MainActor private func makeWallpaper(color: NSColor, prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID()).png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 100).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
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
        // When macOS's native bottom login band is revealed inside the backdrop,
        // the card elevates cleanly above the password field (31% center, min 23%).
        let revealedFloorY = LockScreenWidgetPosition.originY(screenFrame: screen, notchHeight: 32, widgetHeight: 148,
                                                              hasMedia: true, minimalBackdrop: true,
                                                              revealsNativeLogin: true)
        #expect(abs(revealedFloorY - (982 * 0.31 - 74)) < 0.01)
        #expect(revealedFloorY > minimalFloorY)
        // On a compact 768 pt display, the card still clears the shared bottom login reveal band.
        let compact = CGRect(x: 0, y: 0, width: 1280, height: 768)
        let compactRevealedY = LockScreenWidgetPosition.originY(screenFrame: compact, notchHeight: 0, widgetHeight: 148,
                                                                hasMedia: true, minimalBackdrop: true,
                                                                revealsNativeLogin: true)
        let compactClearHeight = LockScreenBackdropMetrics.nativeLoginReveal(for: compact.height).clearHeight
        #expect(compactRevealedY >= compactClearHeight + 12)
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

    @Test @MainActor func sleepPausePreservesComposedBackdropSoWakePresentsFullBackdropImmediately() async throws {
        _ = NSApplication.shared
        try await asyncProfile { preferences in
            try preferences.set(true, for: Preferences.lockScreenBackdrop)
            try preferences.set(false, for: Preferences.lockScreenDepthEffect)

            let tempURL = try makeWallpaper(color: .systemIndigo, prefix: "flux-sleep-wake")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var wallpaperURL: URL? = tempURL
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
                loadWallpaperURL: { wallpaperURL }, readBiometryState: { .ready })
            defer { service.stop() }
            service.setPhase(.unlocked)
            let firstHandle = try service.makeHandle()

            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let initialBackdrop = try #require(service.composedBackdrop)

            // Lock, then simulate display sleep (FeatureRuntime stops the handle, then sets .sleeping).
            service.setPhase(.locked)
            firstHandle.stop()
            service.setPhase(.sleeping)
            #expect(service.composedBackdrop != nil)
            #expect(service.composedBackdrop?.backdrop === initialBackdrop.backdrop)

            // Simulate display wake while still locked (even if desktopWallpaperURL transiently returns nil).
            bridge.attached.removeAll()
            wallpaperURL = nil
            let wakeHandle = try service.makeHandle()
            defer { wakeHandle.stop() }
            service.setPhase(.locked)

            // Full-screen backdrop must already be mounted synchronously on the first wake frame
            // without waiting for an async CoreImage/Vision re-decode.
            let attachedIDs = Set(bridge.attached.joined())
            let wakeWindows = NSApp.windows.filter { window in
                CGWindowID(exactly: window.windowNumber).map { attachedIDs.contains($0) } ?? false
            }
            #expect(wakeWindows.contains { $0.contentViewController is LockScreenBackdropController && $0.isVisible })

            // Full service shutdown must still clear the cached backdrop.
            service.stop()
            #expect(service.composedBackdrop == nil)
        }
    }

    @Test @MainActor func sleepMidComposeReconcilesKeyAndWallpaperChangeDuringSleepClearsStaleBackdrop() async throws {
        _ = NSApplication.shared
        try await asyncProfile { preferences in
            try preferences.set(true, for: Preferences.lockScreenBackdrop)
            try preferences.set(false, for: Preferences.lockScreenDepthEffect)

            let firstURL = try makeWallpaper(color: .systemTeal, prefix: "flux-first-wall")
            let secondURL = try makeWallpaper(color: .systemOrange, prefix: "flux-second-wall")
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }

            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var wallpaperURL: URL? = firstURL
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
                loadWallpaperURL: { wallpaperURL }, readBiometryState: { .ready })
            defer { service.stop() }

            // Start composing, then immediately pause for sleep before compose finishes.
            service.setPhase(.unlocked)
            let interruptedHandle = try service.makeHandle()
            interruptedHandle.stop()
            service.setPhase(.sleeping)

            // Wake must still compose and present (requestedBackdropKey must not stay stuck).
            let wakeHandle = try service.makeHandle()
            service.setPhase(.locked)
            let firstDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop == nil, ContinuousClock.now < firstDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let firstBundle = try #require(service.composedBackdrop)
            #expect(firstBundle.sourceKey.contains(firstURL.path))

            // Sleep again, switch wallpaper while asleep, then wake: old wallpaper must NOT be shown.
            wakeHandle.stop()
            service.setPhase(.sleeping)
            wallpaperURL = secondURL
            let secondHandle = try service.makeHandle()
            defer { secondHandle.stop() }
            service.setPhase(.locked)
            let staleController = NSApp.windows.compactMap {
                $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil
            }.first
            #expect(staleController?.state.sourceKey != firstBundle.sourceKey)

            let secondDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop?.sourceKey.contains(secondURL.path) != true,
                  ContinuousClock.now < secondDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(service.composedBackdrop?.sourceKey.contains(secondURL.path) == true)
        }
    }

    @Test @MainActor func biometryLockoutYieldsOpaqueBackdropAndRestoresWhenReady() async throws {
        _ = NSApplication.shared
        try await asyncProfile { preferences in
            try preferences.set(true, for: Preferences.lockScreenBackdrop)
            try preferences.set(false, for: Preferences.lockScreenDepthEffect)

            let tempURL = try makeWallpaper(color: .systemPurple, prefix: "flux-bio-lockout")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            var biometry: LockScreenBiometryState = .lockedOut
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
                loadWallpaperURL: { tempURL }, readBiometryState: { biometry },
                observeBiometryLockout: true)
            defer { service.stop() }
            service.setPhase(.unlocked)
            let handle = try service.makeHandle()
            defer { handle.stop() }

            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }

            // Lock while Touch ID is locked out (e.g. 48-hour token expired): keep Flux's
            // backdrop mounted while revealing macOS's native bottom login area and hiding
            // Flux's static unlock hint so the native prompt and password box stay visible.
            service.setPhase(.locked)
            let lockedOutBackdrop = try #require(
                NSApp.windows.compactMap { $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil }.first
            )
            #expect(lockedOutBackdrop.state.revealsNativeLogin)
            #expect(service.composedBackdrop != nil)

            // Even if biometry flips ready mid-lock, keep the native bottom login revealed
            // until unlock so an opaque panel never covers an in-progress password entry.
            biometry = .ready
            service.refreshBiometryState()
            #expect(lockedOutBackdrop.state.revealsNativeLogin)

            // Unlock and re-lock while ready: full-screen backdrop restores cleanly.
            service.setPhase(.unlocked)
            service.setPhase(.locked)
            let readyController = try #require(
                NSApp.windows.compactMap { $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil }.first
            )
            #expect(!readyController.state.revealsNativeLogin)
            #expect(readyController.state.unlockHint == "Touch ID or Enter Password")

            // Mid-lock lockout immediately reveals the bottom login band in place while keeping
            // unlockHint populated so SwiftUI fades it smoothly via opacity.
            biometry = .lockedOut
            service.refreshBiometryState()
            #expect(readyController.state.revealsNativeLogin)
            #expect(readyController.state.unlockHint != nil)

            // Non-Touch-ID / unavailable Macs show an accurate password-only hint on lock.
            service.setPhase(.unlocked)
            biometry = .unavailable
            service.setPhase(.locked)
            let unavailableController = try #require(
                NSApp.windows.compactMap { $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil }.first
            )
            #expect(!unavailableController.state.revealsNativeLogin)
            #expect(unavailableController.state.unlockHint == "Enter Password")
        }
    }

    @Test @MainActor func lockScreenWindowsAttachToBridgeBeforeOrderingFront() async throws {
        _ = NSApplication.shared
        final class VisibilityCapturingBridge: LockScreenWindowBridge {
            var firstAttachWasVisible: [CGWindowID: Bool] = [:]
            var missingWindows = 0
            func attach(windowIDs: [CGWindowID]) {
                for id in windowIDs where firstAttachWasVisible[id] == nil {
                    guard let window = NSApp.windows.first(where: { CGWindowID(exactly: $0.windowNumber) == id }) else {
                        missingWindows += 1
                        continue
                    }
                    firstAttachWasVisible[id] = window.isVisible
                }
            }
            func detach() {}
        }
        try await asyncProfile { preferences in
            let tempURL = try makeWallpaper(color: .systemBlue, prefix: "flux-attach-order")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try preferences.set(false, for: Preferences.lockScreenDepthEffect)

            let screen = try #require(NSScreen.screens.first)
            let bridge = VisibilityCapturingBridge()
            let service = NativeLockScreenService(preferences: preferences, availability: { .available },
                makeBridge: { bridge }, geometry: { fixtureGeometry(screen) },
                loadWallpaperURL: { tempURL }, readBiometryState: { .ready })
            defer { service.stop() }
            let handle = try service.makeHandle()
            defer { handle.stop() }

            // 1. Silhouette + interactive card (backdrop off)
            try preferences.set(false, for: Preferences.lockScreenBackdrop)
            service.setPhase(.unlocked)
            service.setPhase(.locked)
            var parser = MediaStream()
            let line = #"{"type":"data","diff":false,"payload":{"title":"Track","artist":"Artist","playing":true,"duration":180,"elapsedTime":10}}"# + "\n"
            let playing = try #require(try parser.append(Data(line.utf8)).compactMap { $0 }.first)
            service.receive(.media(.ready(playing)))

            // 2. Full-screen backdrop (backdrop on)
            service.setPhase(.unlocked)
            try preferences.set(true, for: Preferences.lockScreenBackdrop)
            service.configure()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            service.setPhase(.locked)

            #expect(bridge.missingWindows == 0)
            #expect(bridge.firstAttachWasVisible.count >= 3)
            #expect(bridge.firstAttachWasVisible.values.allSatisfy { !$0 })
        }
    }

    @Test @MainActor func typingPasswordWhileLockedYieldsBackdropAndRestoresOnNextLock() async throws {
        _ = NSApplication.shared
        try await asyncProfile { preferences in
            try preferences.set(true, for: Preferences.lockScreenBackdrop)
            try preferences.set(false, for: Preferences.lockScreenDepthEffect)

            let tempURL = try makeWallpaper(color: .systemMint, prefix: "flux-key-yield")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let screen = try #require(NSScreen.screens.first)
            let bridge = FixtureLockBridge()
            // Simulate Cmd+Ctrl+Q 130ms before lock arrived.
            var uptime: TimeInterval = 1000.13
            var lastKeyDownAt: TimeInterval = 1000.00
            let service = NativeLockScreenService(
                preferences: preferences,
                availability: { .available },
                makeBridge: { bridge },
                geometry: { fixtureGeometry(screen) },
                loadWallpaperURL: { tempURL },
                readBiometryState: { .ready },
                readSecondsSinceKeyDown: { max(0, uptime - lastKeyDownAt) },
                readSystemUptime: { uptime },
                observeKeyboardActivity: true,
                keyboardPollInterval: .milliseconds(15)
            )
            defer { service.stop() }
            service.setPhase(.unlocked)
            let handle = try service.makeHandle()
            defer { handle.stop() }

            let composeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.composedBackdrop == nil, ContinuousClock.now < composeDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }

            // Lock via shortcut with media playing: backdrop stays opaque and card sits in lower lane.
            var parser = MediaStream()
            let line = #"{"type":"data","diff":false,"payload":{"title":"Track","artist":"Artist","playing":true,"duration":180,"elapsedTime":10}}"# + "\n"
            let playing = try #require(try parser.append(Data(line.utf8)).compactMap { $0 }.first)
            service.receive(.media(.ready(playing)))
            service.setPhase(.locked)
            uptime = 1000.20
            try await Task.sleep(for: .milliseconds(50))
            let beforeTyping = try #require(
                NSApp.windows.compactMap { $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil }.first
            )
            let cardBefore = try #require(
                NSApp.windows.first { $0.isVisible && $0.contentViewController is LockScreenContentController }
            )
            let cardOriginBefore = cardBefore.frame.minY
            #expect(!beforeTyping.state.revealsNativeLogin)
            #expect(beforeTyping.state.unlockHint == "Touch ID or Enter Password")

            // User starts typing password: same backdrop controller stays mounted, reveals
            // only the bottom native login band, hides static hint, and elevates the media card.
            uptime = 1000.55
            lastKeyDownAt = 1000.54
            let revealDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !beforeTyping.state.revealsNativeLogin, ContinuousClock.now < revealDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(beforeTyping.state.revealsNativeLogin)
            #expect(beforeTyping.state.unlockHint == "Touch ID or Enter Password")
            #expect(cardBefore.frame.minY > cardOriginBefore)
            #expect(service.composedBackdrop != nil)

            // Unlock and lock again: full-screen backdrop restores cleanly without bottom cutout.
            service.setPhase(.unlocked)
            uptime = 1010.00
            service.setPhase(.locked)
            let restored = try #require(
                NSApp.windows.compactMap { $0.isVisible ? ($0.contentViewController as? LockScreenBackdropController) : nil }.first
            )
            #expect(!restored.state.revealsNativeLogin)
            #expect(restored.state.unlockHint == "Touch ID or Enter Password")
        }
    }
}
