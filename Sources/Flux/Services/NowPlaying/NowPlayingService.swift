import AppKit
import Combine
import ImageIO

/// The one thing the Now Playing widget (and anything else in Notch/) talks
/// to. Composes `MediaRemoteAdapterSource` (preferred — works with any app,
/// reads *and* controls playback) and `ScriptingNowPlayingSource` (fallback —
/// Music/Spotify only) behind a single failover-aware facade, and owns the
/// one artwork downsample/cache so the rest of the app never has to think
/// about raw image bytes.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var state: NowPlayingState?
    /// A single cached, downsampled (≤300pt on the long edge) image — the
    /// previous one is released as soon as a new one replaces it, and it's
    /// only ever recomputed when the underlying artwork bytes actually
    /// change (tracked via `lastArtworkFingerprint`, independent of how often
    /// `state` itself changes for unrelated reasons like the playback
    /// clock).
    @Published private(set) var artwork: NSImage?

    private let adapterSource: MediaRemoteAdapterSource
    private let scriptingSource: ScriptingNowPlayingSource
    private var cancellables = Set<AnyCancellable>()

    private var isActive = false
    private var latestAdapterState: NowPlayingState?
    private var latestScriptingState: NowPlayingState?

    /// M9 (privacy audit): consent gate for the AppleScript scripting-source
    /// failover — settings-driven; set by the wiring agent's Combine sink
    /// from `SettingsStore.notchNowPlayingAppleScriptFallbackEnabled`.
    /// Defaults to `false` so a fresh instance (this service is also
    /// constructed standalone by `NotchSnapshot`/`SettingsRenderer`/
    /// `SelfTest`) never risks scripting Music/Spotify — and the
    /// Automation permission prompt that comes with it — without an
    /// explicit opt-in. While this is `false` and the adapter is
    /// unavailable, `state` simply publishes `nil` (see `recompute()`) so
    /// the widget shows its ordinary empty state rather than nagging for
    /// the fallback.
    var allowScriptingFallback: Bool = false {
        didSet {
            guard allowScriptingFallback != oldValue else { return }
            if Self.shouldEngageScriptingFallback(allowScriptingFallback: allowScriptingFallback,
                                                   adapterAvailable: adapterSource.isAvailable) {
                if isActive { scriptingSource.start() }
            } else {
                scriptingSource.stop()
                latestScriptingState = nil
                recompute()
            }
        }
    }

    /// Pure decision behind "should the scripting fallback actually run
    /// right now" — extracted so `--selftest` can assert the consent gating
    /// directly, without a live Music/Spotify process (this environment
    /// can't run either). Both `setActive` and `observeSources`'s
    /// availability sink route through this single rule rather than each
    /// re-deriving `allowScriptingFallback && !adapterAvailable` inline.
    static func shouldEngageScriptingFallback(allowScriptingFallback: Bool, adapterAvailable: Bool) -> Bool {
        allowScriptingFallback && !adapterAvailable
    }

    /// A cheap stand-in for the last artwork `Data` this service downsampled
    /// — `count` + `hashValue` rather than the encoded bytes themselves, so
    /// this service doesn't hold a *second* full-size copy of the artwork
    /// buffer purely to detect "did it change" (the state pipeline already
    /// keeps its own copy on `state.artworkData`).
    private struct ArtworkFingerprint: Equatable {
        let count: Int
        let hash: Int
    }
    private var lastArtworkFingerprint: ArtworkFingerprint?

    /// Whichever source's data is currently authoritative — drives both
    /// `activeSourceName` and command routing.
    private var usingAdapter = false

    init(adapterSource: MediaRemoteAdapterSource? = nil,
         scriptingSource: ScriptingNowPlayingSource? = nil) {
        // Default parameter values are evaluated in a nonisolated context
        // even though this initializer itself is @MainActor (a quirk of how
        // Swift evaluates default arguments), so the @MainActor-isolated
        // sources are constructed here in the body instead, where we're
        // guaranteed to already be on the main actor.
        self.adapterSource = adapterSource ?? MediaRemoteAdapterSource()
        self.scriptingSource = scriptingSource ?? ScriptingNowPlayingSource()
        observeSources()
    }

    /// For the Settings status row (plan: "for settings UI status row").
    var activeSourceName: String {
        if usingAdapter {
            return state == nil ? "MediaRemote Adapter (idle)" : "MediaRemote Adapter"
        }
        if scriptingSource.isAvailable {
            return "AppleScript (\(scriptingSource.activeAppName ?? "Music/Spotify"))"
        }
        return isActive ? "Unavailable" : "Inactive"
    }

    // MARK: - Lifecycle

    /// `active == false` means the Now Playing widget isn't visible (notch
    /// collapsed to a different widget, or the notch panel itself absent).
    /// Per the perf contract, the *scripting* poll (a real repeating 2s
    /// timer) must stop dead in that case — it's the only piece of this
    /// service that spends CPU when nothing changed. The adapter's `stream`
    /// process is event-driven (blocks in a run loop waiting on MediaRemote
    /// notifications, no polling), so leaving it running while inactive
    /// costs nothing at idle and means the widget has an instant, already-
    /// warm answer the moment it's shown again — that's the "may keep
    /// running (cheap)" the widget-visibility contract allows for.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            adapterSource.start()   // no-op if already running
            if Self.shouldEngageScriptingFallback(allowScriptingFallback: allowScriptingFallback,
                                                   adapterAvailable: adapterSource.isAvailable) {
                scriptingSource.start()
            }
        } else {
            scriptingSource.stop()
        }
    }

    // MARK: - Commands

    /// Routes to the adapter when it's alive (it genuinely supports sending
    /// MediaRemote commands, not just reading — see
    /// `MediaRemoteAdapterSource`), falling back to the AppleScript source
    /// otherwise. Neither source throws on a command it can't currently act
    /// on; this never blocks.
    func send(_ command: NowPlayingCommand) {
        if adapterSource.isAvailable {
            adapterSource.send(command)
        } else {
            scriptingSource.send(command)
        }
    }

    // MARK: - Elapsed-time extrapolation

    /// `state.elapsed` is a sample as of `state.timestamp`, not "right now" —
    /// this projects it forward (only while playing) so a UI can tick a
    /// progress bar every frame without re-polling anything. The projection
    /// is scaled by `state.playbackRate` so a sped-up/slowed-down audiobook
    /// or podcast (1.5x, 2x, 0.5x, ...) doesn't visibly drift out of sync
    /// with the real player between polls; a missing rate (the AppleScript
    /// source never reports one) is treated as normal (1.0) speed. Clamped
    /// to a sane `0.25...4` range first — a source reporting something wild
    /// or malformed shouldn't be able to make this jump the scrubber by
    /// absurd amounts per second. Clamped to `duration` when known, since the
    /// extrapolation is necessarily a rough estimate (rate changes, seeks,
    /// and buffering aren't reflected until the next real update arrives).
    func currentElapsed(at date: Date) -> TimeInterval? {
        guard let state, let elapsed = state.elapsed else { return nil }
        guard state.isPlaying else { return elapsed }
        let rate = min(max(state.playbackRate ?? 1.0, 0.25), 4.0)
        let projected = elapsed + date.timeIntervalSince(state.timestamp) * rate
        guard let duration = state.duration else { return max(0, projected) }
        return min(max(0, projected), duration)
    }

    // MARK: - Source failover

    private func observeSources() {
        adapterSource.statePublisher
            .sink { [weak self] newState in
                guard let self else { return }
                self.latestAdapterState = newState
                self.recompute()
            }
            .store(in: &cancellables)

        adapterSource.availabilityPublisher
            .sink { [weak self] available in
                guard let self, self.isActive else { return }
                // The adapter is the preferred source: as soon as it's alive
                // again there's no reason to keep the AppleScript poller
                // running (and burning its 2s timer) too. `available` is the
                // value this sink was just handed (not a re-read of
                // `adapterSource.isAvailable`) for the same stale-`willSet`
                // read reason documented elsewhere in this codebase (e.g.
                // `AppDelegate.recomputeDuoActive`'s doc comment).
                if available {
                    self.scriptingSource.stop()
                } else if Self.shouldEngageScriptingFallback(allowScriptingFallback: self.allowScriptingFallback,
                                                              adapterAvailable: available) {
                    self.scriptingSource.start()
                }
                self.recompute()
            }
            .store(in: &cancellables)

        scriptingSource.statePublisher
            .sink { [weak self] newState in
                guard let self else { return }
                self.latestScriptingState = newState
                self.recompute()
            }
            .store(in: &cancellables)
    }

    /// The adapter is authoritative whenever it's alive — including when
    /// it's alive but reporting `nil` (nothing playing anywhere), which is
    /// trusted as-is rather than falling back to the Music/Spotify-only
    /// scripting source for a second opinion; MediaRemote already covers
    /// every app scripting can't.
    private func recompute() {
        usingAdapter = adapterSource.isAvailable
        let newState = usingAdapter ? latestAdapterState : latestScriptingState
        guard newState != state else { return }
        state = newState
        updateArtwork(from: newState?.artworkData)
    }

    // MARK: - Fixture injection (dev/testing only)

    /// Directly sets `state`/`artwork`, bypassing the source pipeline
    /// entirely. Used by `NotchSnapshot` (`--snapshot-notch`) to render
    /// deterministic fixture content offscreen, without a real MediaRemote/
    /// AppleScript source running. Never called from a live source path —
    /// `recompute()` would simply overwrite it on the next real update.
    func injectPreviewState(_ state: NowPlayingState?, artwork: NSImage? = nil) {
        self.state = state
        self.artwork = artwork
    }

    // MARK: - Artwork

    private func updateArtwork(from data: Data?) {
        let fingerprint = data.map { ArtworkFingerprint(count: $0.count, hash: $0.hashValue) }
        guard fingerprint != lastArtworkFingerprint else { return }
        lastArtworkFingerprint = fingerprint
        artwork = data.flatMap { Self.downsample($0) }
    }

    /// Downsamples straight from encoded bytes via ImageIO rather than
    /// decoding a full-resolution `NSImage` and resizing it — cheaper, and
    /// the only artwork image kept in memory is this one (the previous
    /// `NSImage` is dropped the moment this replaces it).
    private static func downsample(_ data: Data, maxDimension: CGFloat = 300) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * scale,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
    }
}
