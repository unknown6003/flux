import AppKit
import Combine
import ImageIO

/// The one thing the Now Playing widget (and anything else in Notch/) talks
/// to. Wraps `MediaRemoteAdapterSource` — works with any app, reads *and*
/// controls playback — and owns the one artwork downsample/cache so the rest
/// of the app never has to think about raw image bytes. M11 removed the
/// AppleScript scripting-source fallback (Music/Spotify only, and required
/// scripting either app the first time it engaged, prompting macOS's
/// Automation permission) entirely — the adapter is now the sole source.
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
    private var cancellables = Set<AnyCancellable>()

    /// Read-only outside this file — `LockScreenPresenter` (M9) reads this to
    /// decide whether IT needs to be the one calling `setActive(true)` while
    /// locked (see that type's `shouldActivateForLock`/`didActivateForLock`
    /// doc comments for the shared-ownership contract this makes possible),
    /// without being able to flip it itself and step on whichever widget
    /// might already own the active/inactive call.
    private(set) var isActive = false

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

    init(adapterSource: MediaRemoteAdapterSource? = nil) {
        // Default parameter values are evaluated in a nonisolated context
        // even though this initializer itself is @MainActor (a quirk of how
        // Swift evaluates default arguments), so the @MainActor-isolated
        // source is constructed here in the body instead, where we're
        // guaranteed to already be on the main actor.
        self.adapterSource = adapterSource ?? MediaRemoteAdapterSource()
        observeSource()
    }

    /// For the Settings status row.
    var activeSourceName: String {
        guard adapterSource.isAvailable else { return isActive ? "Unavailable" : "Inactive" }
        return state == nil ? "MediaRemote Adapter (idle)" : "MediaRemote Adapter"
    }

    // MARK: - Lifecycle

    /// `active == false` means the Now Playing widget isn't visible (notch
    /// collapsed to a different widget, or the notch panel itself absent).
    /// The adapter's `stream` process is event-driven (blocks in a run loop
    /// waiting on MediaRemote notifications, no polling), so there's nothing
    /// to stop on `active == false` — leaving it running while inactive
    /// costs nothing at idle and means the widget has an instant, already-
    /// warm answer the moment it's shown again.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            adapterSource.start()   // no-op if already running
        }
    }

    // MARK: - Commands

    /// The adapter genuinely supports sending MediaRemote commands, not just
    /// reading (see `MediaRemoteAdapterSource`) — it's the sole source, so
    /// this is a direct passthrough. A no-op while the adapter is
    /// unavailable rather than throwing; this never blocks.
    func send(_ command: NowPlayingCommand) {
        adapterSource.send(command)
    }

    // MARK: - Elapsed-time extrapolation

    /// `state.elapsed` is a sample as of `state.timestamp`, not "right now" —
    /// this projects it forward (only while playing) so a UI can tick a
    /// progress bar every frame without re-polling anything. The projection
    /// is scaled by `state.playbackRate` so a sped-up/slowed-down audiobook
    /// or podcast (1.5x, 2x, 0.5x, ...) doesn't visibly drift out of sync
    /// with the real player between polls; a missing rate is treated as
    /// normal (1.0) speed. Clamped to a sane `0.25...4` range first — a
    /// source reporting something wild or malformed shouldn't be able to
    /// make this jump the scrubber by absurd amounts per second. Clamped to
    /// `duration` when known, since the extrapolation is necessarily a rough
    /// estimate (rate changes, seeks, and buffering aren't reflected until
    /// the next real update arrives).
    func currentElapsed(at date: Date) -> TimeInterval? {
        guard let state, let elapsed = state.elapsed else { return nil }
        guard state.isPlaying else { return elapsed }
        let rate = min(max(state.playbackRate ?? 1.0, 0.25), 4.0)
        let projected = elapsed + date.timeIntervalSince(state.timestamp) * rate
        guard let duration = state.duration else { return max(0, projected) }
        return min(max(0, projected), duration)
    }

    // MARK: - Source

    private func observeSource() {
        adapterSource.statePublisher
            .sink { [weak self] newState in self?.applyState(newState) }
            .store(in: &cancellables)
    }

    private func applyState(_ newState: NowPlayingState?) {
        guard newState != state else { return }
        state = newState
        updateArtwork(from: newState?.artworkData)
    }

    // MARK: - Fixture injection (dev/testing only)

    /// Directly sets `state`/`artwork`, bypassing the source pipeline
    /// entirely. Used by `NotchSnapshot` (`--snapshot-notch`) to render
    /// deterministic fixture content offscreen, without a real MediaRemote
    /// source running. Never called from a live source path — `applyState`
    /// would simply overwrite it on the next real update.
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
