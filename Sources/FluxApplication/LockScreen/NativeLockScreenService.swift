import AppKit
import FluxCore
import FluxPlatform
import FluxUI

public enum LockScreenServiceError: Error { case unavailable, busy, presentation }

/// Local state and window lifetime, independent of the private space ABI.
/// An available bridge is a required dependency, not inferred from an OS
/// version or from the presence of private symbol names.
@MainActor public final class NativeLockScreenService: LockScreenService {
    public var onChange: (@MainActor () -> Void)?
    public var onTransport: (@MainActor (LockScreenTransportAction) -> Void)?
    public var capability: LockScreenCapability { failureCode == nil ? availability() : .unavailable }
    public private(set) var failureCode: String?
    private let preferences: PreferenceStore
    private let availability: @MainActor () -> LockScreenCapability
    private let screen: @MainActor () -> NSScreen?
    private let now: @MainActor () -> Date
    private let unlockSound: @MainActor () -> Void
    private let makeBridge: @MainActor () throws -> any LockScreenWindowBridge
    private var phase: SessionPhase = .sleeping
    private var handleID: UUID?
    private var media: MediaSnapshot?
    private var activity: ActivityItem?
    private var artwork: NSImage?
    private var artworkID: UUID?
    private var elapsedTask: Task<Void, Never>?
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

    public init(preferences: PreferenceStore,
                availability: @escaping @MainActor () -> LockScreenCapability,
                makeBridge: @escaping @MainActor () throws -> any LockScreenWindowBridge,
                screen: @escaping @MainActor () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first },
                now: @escaping @MainActor () -> Date = { .now },
                unlockSound: @escaping @MainActor () -> Void = { _ = NSSound(named: "Purr")?.play() }) {
        self.preferences = preferences; self.availability = availability; self.makeBridge = makeBridge
        self.screen = screen; self.now = now; self.unlockSound = unlockSound
    }

    deinit { elapsedTask?.cancel() }

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
        render()
    }

    /// An explicit retry first resolves an old detach failure. It never
    /// creates a replacement space while cleanup is still pending.
    public func checkAgain() {
        do { try windows.hide(); failureCode = nil }
        catch { failureCode = "lock.cleanup" }
        render()
        onChange?()
    }

    public func setPhase(_ phase: SessionPhase) {
        let previous = self.phase
        self.phase = phase
        if phase != .locked { clearPresentationWork() }
        if phase == .sleeping { media = nil; activity = nil }
        render()
        if previous == .locked, phase == .unlocked, handleID != nil, enabled,
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
        // Battery has its own system lock-screen UI, as in the old Flux flow.
        activity = item?.kind == .battery ? nil : item
        render()
    }

    public func stop() {
        handleID = nil
        clearPresentationWork()
        media = nil; activity = nil
        hide()
    }

    private func stop(_ id: UUID) {
        guard handleID == id else { return }
        stop()
    }

    private var enabled: Bool {
        preferences.value(for: Preferences.notchEnabled) && preferences.value(for: Preferences.lockScreenEnabled)
    }
    private var presenting: Bool { handleID != nil && enabled && phase == .locked && failureCode == nil }

    private func render() {
        guard presenting, availability() == .available else { clearPresentationWork(); hide(); return }
        guard let screen = screen() else { fail("lock.display"); return }
        let showMedia = preferences.value(for: Preferences.lockScreenNowPlaying)
        if showMedia, let id = media?.artworkID, let bytes = media?.artwork {
            if id != artworkID { artworkID = id; artwork = nil; images.submit(id: id, bytes: bytes) }
        } else if artworkID != nil { images.clear(); artworkID = nil; artwork = nil }
        let playing = showMedia ? media.map { snapshot in
            NowPlayingWidgetState(status: snapshot.playing ? .playing : .paused,
                title: snapshot.title, artist: snapshot.artist, artwork: artwork,
                elapsed: snapshot.elapsed(at: now()) ?? 0, duration: snapshot.duration,
                canGoPrevious: snapshot.canSkip, canGoNext: snapshot.canSkip)
        } : nil
        let caption = preferences.value(for: Preferences.lockScreenActivities) ? activity.flatMap(Self.caption) : nil
        do { try windows.show(.init(media: playing, activity: caption), on: screen) }
        catch { fail(windows.cleanupPending ? "lock.cleanup" : "lock.presentation"); return }
        let ticking = playing?.status == .playing && playing?.duration != nil
        if ticking, elapsedTask == nil {
            elapsedTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.presenting else { return }
                    self.render()
                }
            }
        } else if !ticking { elapsedTask?.cancel(); elapsedTask = nil }
    }

    private func clearPresentationWork() {
        elapsedTask?.cancel(); elapsedTask = nil
        images.clear(); artworkID = nil; artwork = nil
    }

    private func hide() {
        guard !windows.cleanupPending else { return }
        do { try windows.hide() }
        catch { setFailure("lock.cleanup") }
    }

    private func fail(_ code: String) {
        clearPresentationWork()
        var finalCode = code
        if !windows.cleanupPending {
            do { try windows.hide() } catch { finalCode = "lock.cleanup" }
        }
        setFailure(finalCode)
    }

    private func setFailure(_ code: String) {
        let changed = failureCode != code
        failureCode = code
        clearPresentationWork()
        if changed { onChange?() }
    }

    private static func caption(_ item: ActivityItem) -> LockScreenActivityCaption? {
        var symbol: String?
        var text: [String] = []
        for wing in [item.leading, item.trailing] {
            switch wing {
            case .symbol(let value): if symbol == nil { symbol = value }
            case .text(let value): text.append(value)
            case .symbolText(let value, let label): if symbol == nil { symbol = value }; text.append(label)
            case .gauge(_, let value), .soundGauge(_, let value): if symbol == nil { symbol = value }
            case .none, .artwork: break
            }
        }
        let joined = text.joined(separator: " ")
        return joined.isEmpty ? nil : .init(symbolName: symbol, text: joined)
    }
}

@MainActor private final class LockScreenLifetime: FeatureServiceHandle {
    private var finish: (() -> Void)?
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    func stop() { let action = finish; finish = nil; action?() }
}
