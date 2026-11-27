import AppKit
import FluxCore
import FluxPlatform
import FluxUI
import OSLog

public enum LockScreenServiceError: Error { case unavailable, busy, presentation }

/// Local state, sound effects, backdrop/depth composition, and window lifetime
/// for Flux on the lock screen.
@MainActor public final class NativeLockScreenService: LockScreenService {
    private static let logger = Logger(subsystem: "com.flux.menubar", category: "lockscreen")

    public var onChange: (@MainActor () -> Void)?
    public var onTransport: (@MainActor (LockScreenTransportAction) -> Void)?
    public var capability: LockScreenCapability { failureCode == nil ? availability() : .unavailable }
    public private(set) var failureCode: String?
    private let preferences: PreferenceStore
    private let availability: @MainActor () -> LockScreenCapability
    private let geometry: @MainActor () -> LockScreenGeometry?
    private let lockSound: @MainActor () -> Void
    private let unlockSound: @MainActor () -> Void
    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private let readAudioOutput: @MainActor () -> AudioOutputSnapshot
    private let toggleAudioMute: @MainActor () -> Bool
    private let selectAudioOutputDevice: @MainActor (UInt32) -> Bool
    private let loadWallpaperURL: @MainActor () -> URL?
    private let playFallback: @MainActor () -> Void
    private let readBiometryState: @MainActor () -> LockScreenBiometryState
    private let observeBiometryLockout: Bool
    private let readSecondsSinceKeyDown: @MainActor () -> TimeInterval
    private let readCursorVisible: @MainActor () -> Bool?
    private let readSystemUptime: @MainActor () -> TimeInterval
    private let observeKeyboardActivity: Bool
    private let keyboardPollInterval: Duration
    private let mediaClearGracePeriod: Duration
    private let playFallbackDelay: Duration
    private var phase: SessionPhase = .sleeping
    private var biometryState: LockScreenBiometryState = .ready
    /// Once Touch ID is locked out or the user starts typing a password during a
    /// lock session, keep macOS's native bottom login area revealed until unlock so
    /// Flux's Liquid Glass clock and upper backdrop stay on screen while the real
    /// macOS password field and bullets remain visible.
    private var revealsNativeLoginForCurrentLock = false
    private var biometryObserver: BiometryLockoutObserver?
    private var keyboardMonitor: LockScreenKeyboardMonitor?
    private var handleID: UUID?
    private var media: MediaSnapshot?
    private var activity: ActivityItem?
    private var artwork: NSImage?
    private var artworkID: UUID?
    private(set) var composedBackdrop: LockScreenBackdropBundle?
    private var requestedBackdropKey: String?
    private var backdropTask: Task<Void, Never>?
    private var backdropGeneration: UInt64 = 0
    private var mediaClearTask: Task<Void, Never>?
    private var playFallbackTask: Task<Void, Never>?

    private lazy var windows = LockScreenWindows(makeBridge: makeBridge, transport: { [weak self] action in
        self?.handleTransport(action)
    })

    private lazy var images = ArtworkPipeline { [weak self] id, image in
        guard let self, self.presenting, self.artworkID == id else { return }
        self.artwork = image.map { NSImage(cgImage: $0.image, size: .zero) }
        self.render()
    }

    /// The shipping setup: the SkyLight space, minimal Liquid Glass backdrop,
    /// CoreAudio output controls, and synthesized lock/unlock sounds.
    public convenience init(preferences: PreferenceStore) {
        self.init(preferences: preferences,
                  availability: { SkyLightLockScreenSpace.isLoadable ? .available : .unavailable },
                  makeBridge: { try SkyLightWindowBridge() })
    }

    public init(preferences: PreferenceStore,
                availability: @escaping @MainActor () -> LockScreenCapability,
                makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
                lockSound: @escaping @MainActor () -> Void = NativeLockScreenService.playLockSound,
                unlockSound: @escaping @MainActor () -> Void = NativeLockScreenService.playUnlockSound) {
        self.preferences = preferences
        self.availability = availability
        self.makeBridge = makeBridge
        self.lockSound = lockSound
        self.unlockSound = unlockSound
        self.readAudioOutput = AudioOutputRoute.readSnapshot
        self.toggleAudioMute = AudioOutputRoute.toggleMute
        self.selectAudioOutputDevice = AudioOutputRoute.selectDevice
        self.loadWallpaperURL = Self.currentDesktopWallpaperURL
        self.playFallback = MediaKeyFallback.sendPlayPauseKey
        self.readBiometryState = LockScreenBiometry.currentState
        self.observeBiometryLockout = true
        self.readSecondsSinceKeyDown = LockScreenKeyboardActivity.secondsSinceLastKeyDown
        self.readCursorVisible = LockScreenKeyboardActivity.isCursorVisible
        self.readSystemUptime = { ProcessInfo.processInfo.systemUptime }
        self.observeKeyboardActivity = true
        self.keyboardPollInterval = .milliseconds(10)
        self.mediaClearGracePeriod = .seconds(3.5)
        self.playFallbackDelay = .milliseconds(700)
        let cache = LockScreenGeometryCache()
        geometry = { cache.current() }
    }

    /// For fixtures: fixed screen geometry and injectable audio/wallpaper/fallback/biometry/keyboard hooks.
    init(preferences: PreferenceStore,
         availability: @escaping @MainActor () -> LockScreenCapability,
         makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
         geometry: @escaping @MainActor () -> LockScreenGeometry?,
         lockSound: @escaping @MainActor () -> Void = {},
         unlockSound: @escaping @MainActor () -> Void = {},
         loadWallpaperURL: @escaping @MainActor () -> URL? = { nil },
         playFallback: @escaping @MainActor () -> Void = {},
         readBiometryState: @escaping @MainActor () -> LockScreenBiometryState = { .ready },
         observeBiometryLockout: Bool = false,
         readSecondsSinceKeyDown: @escaping @MainActor () -> TimeInterval = { .infinity },
         readCursorVisible: @escaping @MainActor () -> Bool? = { nil },
         readSystemUptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         observeKeyboardActivity: Bool = false,
         keyboardPollInterval: Duration = .milliseconds(10),
         mediaClearGracePeriod: Duration = .seconds(3.5),
         playFallbackDelay: Duration = .milliseconds(700)) {
        self.preferences = preferences
        self.availability = availability
        self.makeBridge = makeBridge
        self.geometry = geometry
        self.lockSound = lockSound
        self.unlockSound = unlockSound
        self.readAudioOutput = AudioOutputRoute.readSnapshot
        self.toggleAudioMute = AudioOutputRoute.toggleMute
        self.selectAudioOutputDevice = AudioOutputRoute.selectDevice
        self.loadWallpaperURL = loadWallpaperURL
        self.playFallback = playFallback
        self.readBiometryState = readBiometryState
        self.observeBiometryLockout = observeBiometryLockout
        self.readSecondsSinceKeyDown = readSecondsSinceKeyDown
        self.readCursorVisible = readCursorVisible
        self.readSystemUptime = readSystemUptime
        self.observeKeyboardActivity = observeKeyboardActivity
        self.keyboardPollInterval = keyboardPollInterval
        self.mediaClearGracePeriod = mediaClearGracePeriod
        self.playFallbackDelay = playFallbackDelay
    }

    public func makeHandle() throws -> any FeatureServiceHandle {
        guard enabled, capability == .available else { throw LockScreenServiceError.unavailable }
        guard handleID == nil else { throw LockScreenServiceError.busy }
        let id = UUID()
        handleID = id
        windows.appearance = Self.appearance(preferences.value(for: Preferences.appearance))
        syncBiometry()
        prewarmBackdropIfNeeded()
        render()
        guard failureCode == nil else {
            clearBiometryObserver()
            clearKeyboardObserver()
            handleID = nil
            throw LockScreenServiceError.presentation
        }
        return LockScreenLifetime { [weak self] in self?.stop(id) }
    }

    public func configure() {
        if !enabled { stop(); return }
        windows.appearance = Self.appearance(preferences.value(for: Preferences.appearance))
        syncBiometry()
        prewarmBackdropIfNeeded()
        render()
    }

    /// An explicit retry first resolves an old detach failure. It never
    /// creates a replacement space while cleanup is still pending.
    public func checkAgain() {
        do { try windows.hide(animated: false); failureCode = nil }
        catch { failureCode = "lock.cleanup" }
        syncBiometry()
        prewarmBackdropIfNeeded()
        render()
        onChange?()
    }

    public func setPhase(_ phase: SessionPhase) {
        let previous = self.phase
        self.phase = phase
        if phase != .locked {
            revealsNativeLoginForCurrentLock = false
            cancelPlayFallback()
            if mediaClearTask != nil {
                mediaClearTask?.cancel()
                mediaClearTask = nil
                media = nil
            }
            clearArtwork()
        }
        if phase == .sleeping { media = nil; activity = nil }
        syncBiometry()
        let wasShowing = windows.isShowing
        render(animated: true)
        if phase == .unlocked {
            prewarmBackdropIfNeeded()
        }
        if previous == .unlocked, phase == .locked, handleID != nil, enabled, failureCode == nil,
           preferences.value(for: Preferences.lockScreenLockSound) {
            lockSound()
        }
        if previous == .locked, phase == .unlocked, wasShowing, handleID != nil, enabled,
           preferences.value(for: Preferences.lockScreenUnlockSound) {
            unlockSound()
        }
    }

    func refreshBiometryState() {
        guard presenting else { return }
        let next = readBiometryState()
        guard next != biometryState else { return }
        biometryState = next
        if next == .lockedOut {
            revealNativeLogin(reason: "biometryLockout")
            return
        }
        syncKeyboardObserver()
        render()
    }

    private func revealNativeLogin(reason: String) {
        guard !revealsNativeLoginForCurrentLock else { return }
        revealsNativeLoginForCurrentLock = true
        clearKeyboardObserver()
        Self.logger.notice("lock.nativeLogin.reveal reason=\(reason, privacy: .public)")
        // Skip synchronous wallpaper XPC lookup on keystroke #1 so the reveal starts on the next frame.
        render(syncWallpaper: readyBackdrop == nil)
    }

    private func syncBiometry() {
        if phase == .locked {
            biometryState = readBiometryState()
            if biometryState == .lockedOut {
                if !revealsNativeLoginForCurrentLock {
                    Self.logger.notice("lock.nativeLogin.reveal reason=biometryLockout")
                }
                revealsNativeLoginForCurrentLock = true
            }
        } else {
            revealsNativeLoginForCurrentLock = false
        }
        syncBiometryObserver()
        syncKeyboardObserver()
    }

    private func syncBiometryObserver() {
        guard presenting, observeBiometryLockout else {
            clearBiometryObserver()
            return
        }
        guard biometryObserver == nil else { return }
        biometryObserver = BiometryLockoutObserver { [weak self] in
            self?.refreshBiometryState()
        }
    }

    private func clearBiometryObserver() {
        biometryObserver?.stop()
        biometryObserver = nil
    }

    private func syncKeyboardObserver() {
        let shouldMonitor = presenting
            && observeKeyboardActivity
            && preferences.value(for: Preferences.lockScreenBackdrop)
            && biometryState != .lockedOut
            && !revealsNativeLoginForCurrentLock
        guard shouldMonitor else {
            clearKeyboardObserver()
            return
        }
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = LockScreenKeyboardMonitor(
            pollInterval: keyboardPollInterval,
            readSystemUptime: readSystemUptime,
            readSecondsSinceKeyDown: readSecondsSinceKeyDown,
            readCursorVisible: readCursorVisible
        ) { [weak self] in
            self?.revealNativeLogin(reason: "keyboard")
        }
    }

    private func clearKeyboardObserver() {
        keyboardMonitor?.stop()
        keyboardMonitor = nil
    }

    public func receive(_ event: WidgetEvent) {
        guard handleID != nil, enabled else { return }
        if case .media(let value) = event {
            switch value {
            case .ready(let snapshot?):
                cancelMediaClear()
                if snapshot.playing { cancelPlayFallback() }
                media = snapshot
                render()
            case .ready(nil):
                if presenting, media != nil {
                    scheduleMediaClear()
                } else {
                    cancelMediaClear()
                    cancelPlayFallback()
                    media = nil
                    render()
                }
            case .unavailable:
                cancelMediaClear()
                cancelPlayFallback()
                media = nil
                render()
            case .starting:
                if !presenting {
                    cancelMediaClear()
                    media = nil
                }
            }
        }
    }

    public func updateActivity(_ item: ActivityItem?) {
        guard handleID != nil, enabled else { return }
        activity = item
        render()
    }

    public func stop() {
        tearDown(keepBackdrop: false)
    }

    private func stop(_ id: UUID) {
        guard handleID == id else { return }
        // Sleep or temporary demand pause while enabled: close visible windows
        // immediately while keeping any already-composed wallpaper bundle so
        // waking onto the lock screen presents the full backdrop on frame 1.
        tearDown(keepBackdrop: enabled)
    }

    private func tearDown(keepBackdrop: Bool) {
        handleID = nil
        revealsNativeLoginForCurrentLock = false
        clearBiometryObserver()
        clearKeyboardObserver()
        cancelMediaClear()
        cancelPlayFallback()
        clearArtwork()
        if keepBackdrop {
            // Cancel any in-flight compose and align requestedBackdropKey with the
            // retained bundle so a sleep mid-compose never blocks wake recomposition.
            backdropGeneration &+= 1
            backdropTask?.cancel()
            backdropTask = nil
            requestedBackdropKey = composedBackdrop?.sourceKey
        } else {
            clearBackdrop()
        }
        windows.discardPrewarmedBackdrop()
        media = nil; activity = nil
        hide(animated: false)
    }

    private var enabled: Bool {
        preferences.value(for: Preferences.notchEnabled) && preferences.value(for: Preferences.lockScreenEnabled)
    }
    private var presenting: Bool { handleID != nil && enabled && phase == .locked && failureCode == nil }

    func handleTransport(_ action: LockScreenTransportAction) {
        guard presenting else { return }
        switch action {
        case .toggleMute:
            _ = toggleAudioMute()
            render()
        case .selectAudioOutput(let id):
            _ = selectAudioOutputDevice(id)
            render()
        case .previous, .play, .pause, .togglePlayPause, .next, .seek:
            guard preferences.value(for: Preferences.lockScreenNowPlaying), media != nil else { return }
            if case .seek(let value) = action, !value.isFinite || value < 0 || value > (media?.duration ?? 0) { return }
            cancelPlayFallback()
            onTransport?(action)
            let isResuming = action == .play || (action == .togglePlayPause && media?.playing == false)
            if isResuming {
                schedulePlayFallback()
            }
        }
    }

    private func scheduleMediaClear() {
        guard mediaClearTask == nil else { return }
        let delay = mediaClearGracePeriod
        mediaClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.mediaClearTask = nil
            self.cancelPlayFallback()
            self.media = nil
            self.render()
        }
    }

    private func cancelMediaClear() {
        mediaClearTask?.cancel()
        mediaClearTask = nil
    }

    private func schedulePlayFallback() {
        cancelPlayFallback()
        let delay = playFallbackDelay
        playFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.presenting, self.media?.playing != true else { return }
            self.playFallbackTask = nil
            self.playFallback()
        }
    }

    private func cancelPlayFallback() {
        playFallbackTask?.cancel()
        playFallbackTask = nil
    }

    /// Only expose a composed backdrop whose key matches the active pipeline request
    /// so a stale pre-sleep wallpaper can never be prewarmed or presented.
    private var readyBackdrop: LockScreenBackdropBundle? {
        guard let bundle = composedBackdrop, bundle.sourceKey == requestedBackdropKey else { return nil }
        return bundle
    }

    private func prewarmBackdropIfNeeded() {
        guard handleID != nil, enabled, failureCode == nil, availability() == .available else { return }
        let showBackdrop = preferences.value(for: Preferences.lockScreenBackdrop)
        guard showBackdrop else {
            clearBackdrop()
            windows.discardPrewarmedBackdrop()
            return
        }
        guard let geom = geometry() else { return }
        let showDepth = preferences.value(for: Preferences.lockScreenDepthEffect)
        let blurEdges = preferences.value(for: Preferences.lockScreenEdgeBlur)
        syncBackdropPipeline(blurEdges: blurEdges, depthEffect: showDepth, screenSize: geom.screenFrame.size)
        if !presenting, let bundle = readyBackdrop {
            windows.prewarmBackdrop(makeBackdropState(bundle: bundle, showDepth: showDepth), geometry: geom)
        }
    }

    private func render(animated: Bool = false, syncWallpaper: Bool = true) {
        guard presenting, availability() == .available else { clearArtwork(); hide(animated: animated); return }
        guard let geometry = geometry() else { hide(animated: false); return }

        let showMedia = preferences.value(for: Preferences.lockScreenNowPlaying)
        let showBackdrop = preferences.value(for: Preferences.lockScreenBackdrop)
        let showDepth = preferences.value(for: Preferences.lockScreenDepthEffect)
        let blurEdges = preferences.value(for: Preferences.lockScreenEdgeBlur)

        if showMedia, let id = media?.artworkID, let bytes = media?.artwork {
            if id != artworkID {
                artworkID = id
                // Keep prior thumbnail until the new one decodes so track switches don't flash blank.
                images.submit(id: id, bytes: bytes)
            }
        } else if artworkID != nil || artwork != nil {
            images.clear(); artworkID = nil; artwork = nil
        }

        if showBackdrop {
            if syncWallpaper {
                syncBackdropPipeline(blurEdges: blurEdges, depthEffect: showDepth, screenSize: geometry.screenFrame.size)
            }
        } else {
            clearBackdrop()
            windows.discardPrewarmedBackdrop()
        }

        let playing = showMedia ? media.map { snapshot in
            NowPlayingWidgetState(status: snapshot.playing ? .playing : .paused,
                                  title: snapshot.title, artist: snapshot.artist, artwork: artwork,
                                  elapsed: snapshot.elapsed(at: .now) ?? 0, duration: snapshot.duration,
                                  canGoPrevious: snapshot.canSkip, canGoNext: snapshot.canSkip)
        } : nil
        let audioState: LockScreenAudioOutputState? = playing != nil ? makeAudioOutputState() : nil
        let caption = preferences.value(for: Preferences.lockScreenActivities) ? activity.flatMap(Self.caption) : nil

        let backdropState: LockScreenBackdropState
        let revealsNativeLogin = biometryState == .lockedOut || revealsNativeLoginForCurrentLock
        if showBackdrop, let bundle = readyBackdrop {
            backdropState = makeBackdropState(
                bundle: bundle,
                showDepth: showDepth,
                revealsNativeLogin: revealsNativeLogin
            )
        } else {
            backdropState = .empty
        }

        windows.appearance = Self.appearance(preferences.value(for: Preferences.appearance))
        do {
            try windows.show(.init(media: playing, activity: caption, audioOutput: audioState),
                             backdrop: backdropState,
                             geometry: geometry)
        } catch {
            fail(windows.cleanupPending ? "lock.cleanup" : "lock.presentation")
        }
    }

    private func makeBackdropState(bundle: LockScreenBackdropBundle,
                                   showDepth: Bool,
                                   revealsNativeLogin: Bool = false) -> LockScreenBackdropState {
        // Keep unlockHint populated even while revealing native login so LockScreenBackdropView
        // can animate its opacity fade smoothly instead of unmounting the view abruptly.
        let hint = biometryState == .ready ? "Touch ID or Enter Password" : "Enter Password"
        return LockScreenBackdropState(
            sourceKey: bundle.sourceKey,
            backdrop: bundle.backdrop,
            foregroundCutout: showDepth ? bundle.foregroundCutout : nil,
            showsDepthEffect: showDepth && bundle.foregroundCutout != nil,
            unlockHint: hint,
            revealsNativeLogin: revealsNativeLogin
        )
    }

    private func makeAudioOutputState() -> LockScreenAudioOutputState {
        let snap = readAudioOutput()
        let devices = snap.devices.map {
            LockScreenAudioDevice(id: $0.id, name: $0.name, symbolName: $0.symbolName, isSelected: $0.isDefault)
        }
        return LockScreenAudioOutputState(
            isMuted: snap.isMuted,
            canMute: snap.canMute,
            currentSymbolName: snap.currentDevice?.symbolName ?? "display",
            currentDeviceName: snap.currentDevice?.name ?? "Speakers",
            devices: devices
        )
    }

    private func resolvedWallpaperURL() -> (LockScreenWallpaper, URL)? {
        let choice = preferences.value(for: Preferences.lockScreenWallpaper)
        if let resource = choice.resourceName,
           let bundled = LockScreenBackdropComposer.bundledWallpaperURL(named: resource) {
            return (choice, bundled)
        }
        if let desktop = loadWallpaperURL() {
            return (.system, desktop)
        }
        return nil
    }

    private func syncBackdropPipeline(blurEdges: Bool, depthEffect: Bool, screenSize: CGSize) {
        guard let (choice, wallpaperURL) = resolvedWallpaperURL() else {
            // NSWorkspace.desktopImageURL can transiently return nil during lock/wake;
            // only clear a cached backdrop when unlocked.
            if phase == .unlocked {
                clearBackdrop()
            }
            return
        }

        let mtime = (try? wallpaperURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let sizeKey = "\(Int(screenSize.width.rounded()))x\(Int(screenSize.height.rounded()))"
        let key = "\(choice.rawValue)|\(wallpaperURL.path)|\(Int(mtime))|\(sizeKey)|blur\(blurEdges ? 1 : 0)|depth\(depthEffect ? 1 : 0)"
        if requestedBackdropKey == key { return }
        if composedBackdrop?.sourceKey != key {
            composedBackdrop = nil
            windows.discardPrewarmedBackdrop()
        }
        requestedBackdropKey = key
        backdropGeneration &+= 1
        let generation = backdropGeneration
        backdropTask?.cancel()

        backdropTask = Task { @MainActor [weak self] in
            let matchSystemFill = choice == .system
            let bundle: LockScreenBackdropBundle? = await Task.detached(priority: .userInitiated) {
                guard let chosen = LockScreenBackdropComposer.decodeImage(at: wallpaperURL, maxPixels: 2560),
                      !Task.isCancelled else { return nil }
                return LockScreenBackdropComposer.compose(
                    sourceKey: key,
                    image: chosen,
                    targetAspectSize: screenSize,
                    blurEdges: blurEdges,
                    matchSystemFill: matchSystemFill,
                    includeDepthEffect: depthEffect
                )
            }.value
            guard !Task.isCancelled, let self, self.backdropGeneration == generation else { return }
            self.backdropTask = nil
            guard self.handleID != nil, self.enabled, let bundle else {
                self.requestedBackdropKey = self.composedBackdrop?.sourceKey
                return
            }
            self.composedBackdrop = bundle
            if self.presenting {
                self.render()
            } else if let geom = self.geometry(),
                      self.preferences.value(for: Preferences.lockScreenBackdrop) {
                let showDepth = self.preferences.value(for: Preferences.lockScreenDepthEffect)
                self.windows.prewarmBackdrop(self.makeBackdropState(bundle: bundle, showDepth: showDepth), geometry: geom)
            }
        }
    }

    private func clearBackdrop() {
        backdropGeneration &+= 1
        backdropTask?.cancel()
        backdropTask = nil
        requestedBackdropKey = nil
        composedBackdrop = nil
    }

    private func clearArtwork() {
        images.clear(); artworkID = nil; artwork = nil
    }

    private func hide(animated: Bool) {
        guard !windows.cleanupPending else { return }
        do { try windows.hide(animated: animated) }
        catch { setFailure("lock.cleanup") }
    }

    private func fail(_ code: String) {
        clearBiometryObserver()
        clearKeyboardObserver()
        clearArtwork()
        clearBackdrop()
        windows.discardPrewarmedBackdrop()
        var finalCode = code
        if !windows.cleanupPending {
            do { try windows.hide(animated: false) } catch { finalCode = "lock.cleanup" }
        }
        setFailure(finalCode)
    }

    private func setFailure(_ code: String) {
        let changed = failureCode != code
        failureCode = code
        clearArtwork()
        if changed { onChange?() }
    }

    /// Pill caption: battery and level HUDs stay out, text is trailing or leading, symbol from leading wing.
    static func caption(_ item: ActivityItem) -> LockScreenActivityCaption? {
        guard item.kind != .battery, !item.kind.isBarHUD else { return nil }
        func text(_ wing: ActivityWing) -> String? {
            switch wing {
            case .text(let value), .symbolText(_, let value): return value
            case .none, .symbol, .gauge, .soundGauge, .artwork: return nil
            }
        }
        guard let caption = text(item.trailing) ?? text(item.leading) else { return nil }
        let symbol: String?
        switch item.leading {
        case .symbol(let name), .symbolText(let name, _), .gauge(_, let name), .soundGauge(_, let name): symbol = name
        case .none, .text, .artwork: symbol = nil
        }
        return LockScreenActivityCaption(symbolName: symbol, text: caption)
    }

    private static func appearance(_ value: Appearance) -> NSAppearance? {
        switch value {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    private static func currentDesktopWallpaperURL() -> URL? {
        guard let screen = NSScreen.builtInNotchedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        return LockScreenBackdropComposer.desktopWallpaperURL(for: screen)
    }

    public static func playLockSound() {
        LockScreenSoundPlayer.playLock()
    }

    public static func playUnlockSound() {
        LockScreenSoundPlayer.playUnlock()
    }
}

/// The last good screen and notch geometry. At lock time macOS can stop
/// reporting notch auxiliary areas, so we remember the last unlocked frame.
@MainActor final class LockScreenGeometryCache {
    static let defaultsKey = "flux.lockScreen.notchGeometry.v2"
    private var cached: LockScreenGeometry?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cached = Self.load(from: defaults)
    }

    func current() -> LockScreenGeometry? {
        if let screen = NSScreen.builtInNotchedScreen, let notch = screen.physicalNotchRect {
            let live = LockScreenGeometry(notch: notch, screenFrame: screen.frame)
            if live != cached {
                cached = live
                save(live)
            }
            return live
        }
        if let cached { return cached }
        if let screen = NSScreen.main ?? NSScreen.screens.first,
           screen.frame.width > 0, screen.frame.height > 0 {
            return LockScreenGeometry(notch: .zero, screenFrame: screen.frame)
        }
        return nil
    }

    private func save(_ value: LockScreenGeometry) {
        var values: [String: Any] = [:]
        Self.write(value.notch, to: &values, prefix: "notch")
        Self.write(value.screenFrame, to: &values, prefix: "screen")
        defaults.set(values, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> LockScreenGeometry? {
        guard let values = defaults.dictionary(forKey: defaultsKey),
              let notch = rect(in: values, prefix: "notch"), let screen = rect(in: values, prefix: "screen") else { return nil }
        return LockScreenGeometry(notch: notch, screenFrame: screen)
    }

    private static func rect(in values: [String: Any], prefix: String) -> CGRect? {
        func number(_ suffix: String) -> CGFloat? {
            (values["\(prefix).\(suffix)"] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
              width > 0, height > 0, x.isFinite, y.isFinite else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func write(_ rect: CGRect, to values: inout [String: Any], prefix: String) {
        values["\(prefix).x"] = NSNumber(value: Double(rect.origin.x))
        values["\(prefix).y"] = NSNumber(value: Double(rect.origin.y))
        values["\(prefix).width"] = NSNumber(value: Double(rect.size.width))
        values["\(prefix).height"] = NSNumber(value: Double(rect.size.height))
    }
}

@MainActor private final class LockScreenLifetime: FeatureServiceHandle {
    private var finish: (() -> Void)?
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    func stop() { let action = finish; finish = nil; action?() }
}
