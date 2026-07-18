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
    /// change (tracked via `lastArtworkData`, independent of how often
    /// `state` itself changes for unrelated reasons like the playback
    /// clock).
    @Published private(set) var artwork: NSImage?

    private let adapterSource: MediaRemoteAdapterSource
    private let scriptingSource: ScriptingNowPlayingSource
    private var cancellables = Set<AnyCancellable>()

    private var isActive = false
    private var latestAdapterState: NowPlayingState?
    private var latestScriptingState: NowPlayingState?
    private var lastArtworkData: Data?

    /// Whichever source's data is currently authoritative — drives both
    /// `activeSourceName` and command routing.
    private var usingAdapter = false

    init(adapterSource: MediaRemoteAdapterSource = MediaRemoteAdapterSource(),
         scriptingSource: ScriptingNowPlayingSource = ScriptingNowPlayingSource()) {
        self.adapterSource = adapterSource
        self.scriptingSource = scriptingSource
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
            if !adapterSource.isAvailable {
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
    /// progress bar every frame without re-polling anything. Clamped to
    /// `duration` when known, since the extrapolation is necessarily a rough
    /// estimate (playback rate changes, seeks, and buffering aren't
    /// reflected until the next real update arrives).
    func currentElapsed(at date: Date) -> TimeInterval? {
        guard let state, let elapsed = state.elapsed else { return nil }
        guard state.isPlaying else { return elapsed }
        let projected = elapsed + date.timeIntervalSince(state.timestamp)
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
                // running (and burning its 2s timer) too.
                if available {
                    self.scriptingSource.stop()
                } else {
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
        guard data != lastArtworkData else { return }
        lastArtworkData = data
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
