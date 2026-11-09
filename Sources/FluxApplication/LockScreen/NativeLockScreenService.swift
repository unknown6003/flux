import AppKit
import FluxCore
import FluxPlatform
import FluxUI

public enum LockScreenServiceError: Error { case unavailable, busy, presentation }

/// Local state and window lifetime for Flux on the lock screen. The default
/// setup uses the 0.21.35 SkyLight space: the feature is available whenever
/// that private bridge loads, and "not available" only when it does not.
@MainActor public final class NativeLockScreenService: LockScreenService {
    public var onChange: (@MainActor () -> Void)?
    public var onTransport: (@MainActor (LockScreenTransportAction) -> Void)?
    public var capability: LockScreenCapability { failureCode == nil ? availability() : .unavailable }
    public private(set) var failureCode: String?
    private let preferences: PreferenceStore
    private let availability: @MainActor () -> LockScreenCapability
    private let geometry: @MainActor () -> LockScreenGeometry?
    private let unlockSound: @MainActor () -> Void
    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private var phase: SessionPhase = .sleeping
    private var handleID: UUID?
    private var media: MediaSnapshot?
    private var activity: ActivityItem?
    private var artwork: NSImage?
    private var artworkID: UUID?
    private lazy var windows = LockScreenWindows(makeBridge: makeBridge, transport: { [weak self] action in
        guard let self, self.presenting, self.preferences.value(for: Preferences.lockScreenNowPlaying), self.media != nil else { return }
        if case .seek(let value) = action, !value.isFinite || value < 0 || value > (self.media?.duration ?? 0) { return }
        self.onTransport?(action)
    })
    private lazy var images = ArtworkPipeline { [weak self] id, image in
        guard let self, self.presenting, self.artworkID == id else { return }
        self.artwork = image.map { NSImage(cgImage: $0.image, size: .zero) }
        self.render()
    }

    /// The shipping setup: the SkyLight space and the built-in notch.
    public convenience init(preferences: PreferenceStore) {
        self.init(preferences: preferences,
                  availability: { SkyLightLockScreenSpace.isLoadable ? .available : .unavailable },
                  makeBridge: { try SkyLightWindowBridge() })
    }

    public init(preferences: PreferenceStore,
                availability: @escaping @MainActor () -> LockScreenCapability,
                makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
                unlockSound: @escaping @MainActor () -> Void = NativeLockScreenService.playUnlockSound) {
        self.preferences = preferences; self.availability = availability; self.makeBridge = makeBridge
        self.unlockSound = unlockSound
        let cache = LockScreenGeometryCache()
        geometry = { cache.current() }
    }

    /// For fixtures: a fixed screen whose notch is `notch`, or the screen's own.
    init(preferences: PreferenceStore,
         availability: @escaping @MainActor () -> LockScreenCapability,
         makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
         geometry: @escaping @MainActor () -> LockScreenGeometry?,
         unlockSound: @escaping @MainActor () -> Void) {
        self.preferences = preferences; self.availability = availability; self.makeBridge = makeBridge
        self.geometry = geometry; self.unlockSound = unlockSound
    }

    public func makeHandle() throws -> any FeatureServiceHandle {
        guard enabled, capability == .available else { throw LockScreenServiceError.unavailable }
        guard handleID == nil else { throw LockScreenServiceError.busy }
        let id = UUID()
        handleID = id
        render()
        guard failureCode == nil else { handleID = nil; throw LockScreenServiceError.presentation }
        return LockScreenLifetime { [weak self] in self?.stop(id) }
    }

    public func configure() {
        if !enabled { stop(); return }
        windows.appearance = Self.appearance(preferences.value(for: Preferences.appearance))
        render()
    }

    /// An explicit retry first resolves an old detach failure. It never
    /// creates a replacement space while cleanup is still pending.
    public func checkAgain() {
        do { try windows.hide(animated: false); failureCode = nil }
        catch { failureCode = "lock.cleanup" }
        render()
        onChange?()
    }

    public func setPhase(_ phase: SessionPhase) {
        let previous = self.phase
        self.phase = phase
        if phase != .locked { clearArtwork() }
        if phase == .sleeping { media = nil; activity = nil }
        let wasShowing = windows.isShowing
        render(animated: true)
        if previous == .locked, phase == .unlocked, wasShowing, handleID != nil, enabled,
           preferences.value(for: Preferences.lockScreenUnlockSound) { unlockSound() }
    }

    public func receive(_ event: WidgetEvent) {
        guard handleID != nil, enabled else { return }
        if case .media(let value) = event {
            if case .ready(let snapshot) = value { media = snapshot }
            else { media = nil }
            render()
        }
    }

    public func updateActivity(_ item: ActivityItem?) {
        guard handleID != nil, enabled else { return }
        activity = item
        render()
    }

    public func stop() {
        handleID = nil
        clearArtwork()
        media = nil; activity = nil
        hide(animated: false)
    }

    private func stop(_ id: UUID) {
        guard handleID == id else { return }
        stop()
    }

    private var enabled: Bool {
        preferences.value(for: Preferences.notchEnabled) && preferences.value(for: Preferences.lockScreenEnabled)
    }
    private var presenting: Bool { handleID != nil && enabled && phase == .locked && failureCode == nil }

    private func render(animated: Bool = false) {
        guard presenting, availability() == .available else { clearArtwork(); hide(animated: animated); return }
        // 0.21.35 showed nothing, and reported nothing, without notch geometry.
        guard let geometry = geometry() else { hide(animated: false); return }
        let showMedia = preferences.value(for: Preferences.lockScreenNowPlaying)
        if showMedia, let id = media?.artworkID, let bytes = media?.artwork {
            if id != artworkID { artworkID = id; artwork = nil; images.submit(id: id, bytes: bytes) }
        } else if artworkID != nil { clearArtwork() }
        let playing = showMedia ? media.map { snapshot in
            NowPlayingWidgetState(status: snapshot.playing ? .playing : .paused,
                title: snapshot.title, artist: snapshot.artist, artwork: artwork,
                elapsed: snapshot.elapsed(at: .now) ?? 0, duration: snapshot.duration,
                canGoPrevious: snapshot.canSkip, canGoNext: snapshot.canSkip)
        } : nil
        let caption = preferences.value(for: Preferences.lockScreenActivities) ? activity.flatMap(Self.caption) : nil
        windows.appearance = Self.appearance(preferences.value(for: Preferences.appearance))
        do { try windows.show(.init(media: playing, activity: caption), geometry: geometry) }
        catch { fail(windows.cleanupPending ? "lock.cleanup" : "lock.presentation") }
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
        clearArtwork()
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

    /// The 0.21.35 pill: battery stays out, the text is the trailing text or
    /// else the leading text, and the symbol comes from the leading wing.
    static func caption(_ item: ActivityItem) -> LockScreenActivityCaption? {
        guard item.kind != .battery else { return nil }
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

    private static var unlockSoundPlayer: NSSound?

    /// The 0.21.35 unlock sound: Purr, or the first system sound that exists.
    public static func playUnlockSound() {
        let sound = NSSound(named: "Purr") ?? NSSound(named: "Pop") ?? NSSound(named: "Glass") ?? NSSound(named: "Tink")
        unlockSoundPlayer = sound
        sound?.stop()
        sound?.play()
    }
}

/// The last good notch geometry. At lock time macOS can stop reporting the
/// notch areas, so 0.21.35 kept the last rect in defaults under this key.
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
        return cached
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
