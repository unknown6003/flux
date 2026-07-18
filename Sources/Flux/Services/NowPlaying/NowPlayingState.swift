import Foundation

/// A single, source-agnostic snapshot of "what's playing" — produced by either
/// `MediaRemoteAdapterSource` (MediaRemote via the vendored perl+framework
/// adapter, works for any app) or `ScriptingNowPlayingSource` (AppleScript,
/// Music/Spotify only), and consumed by `NowPlayingService` and the Now
/// Playing widget. `elapsed`/`timestamp` are a paired sample — see
/// `NowPlayingService.currentElapsed(at:)` for extrapolating "now".
struct NowPlayingState: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    /// The playback position as of `timestamp`, in seconds. Not "right now" —
    /// callers that want a live-updating position must extrapolate using
    /// `timestamp` and `isPlaying` (see `NowPlayingService.currentElapsed`).
    var elapsed: TimeInterval?
    var isPlaying: Bool
    /// Raw, undecoded image bytes (JPEG/PNG/TIFF — whatever the source app
    /// reports). Downsampling to a display-ready `NSImage` is
    /// `NowPlayingService`'s job, not this layer's.
    var artworkData: Data?
    var sourceBundleID: String?
    /// When `elapsed` was sampled. For the MediaRemote adapter this is the
    /// adapter's own `timestamp` field; for the AppleScript source it's the
    /// moment the poll ran (AppleScript has no equivalent field).
    var timestamp: Date
}

/// Playback controls the UI can issue, independent of which source ends up
/// handling them (see `NowPlayingService.send(_:)` for the routing).
enum NowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    /// Absolute seek target, in seconds.
    case seek(TimeInterval)
}

// MARK: - MediaRemote adapter JSON schema

/// Mirrors the flat metadata dictionary the vendored `mediaremote-adapter`
/// emits for both its `get` command and the `payload` field of each `stream`
/// line — verified field-by-field against the pinned source in
/// `Vendor/mediaremote-adapter` (`src/adapter/keys.m`, `src/adapter/now_playing.m`,
/// `src/utility/helpers.m`). Only decodes the subset Flux actually uses;
/// upstream documents several more keys (chapter/genre/queue/rating/etc.)
/// that are simply ignored here. Every field is optional because:
///   - `stream` sends *partial* dictionaries when diffing (a field absent
///     from one line doesn't mean the value is unset, just unchanged — see
///     `MediaRemoteAdapterSource` for the merge logic that turns a sequence
///     of these into one coherent state), and
///   - even a "get"/full snapshot payload legitimately omits fields the
///     current app/track doesn't report (e.g. no album, no artwork yet).
struct MediaRemoteAdapterPayload: Decodable, Equatable {
    var processIdentifier: Int?
    var bundleIdentifier: String?
    var parentApplicationBundleIdentifier: String?
    var playing: Bool?
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds (upstream's default unit; Flux never passes `--micros`).
    var duration: Double?
    /// Seconds, as of `timestamp` (upstream's `elapsedTime` key).
    var elapsedTime: Double?
    var timestamp: Date?
    var artworkMimeType: String?
    /// Base64 (upstream encodes with `NSData.base64EncodedStringWithOptions:`,
    /// no line wrapping) — still-encoded here; decoding to `Data` happens in
    /// `NowPlayingState.init(payload:)` (and is skipped when unchanged by
    /// `MediaRemoteAdapterSource`, since artwork payloads can be sizeable).
    var artworkData: String?

    private enum CodingKeys: String, CodingKey {
        case processIdentifier, bundleIdentifier, parentApplicationBundleIdentifier
        case playing, title, artist, album, duration, elapsedTime, timestamp
        case artworkMimeType, artworkData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processIdentifier = try c.decodeIfPresent(Int.self, forKey: .processIdentifier)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        parentApplicationBundleIdentifier =
            try c.decodeIfPresent(String.self, forKey: .parentApplicationBundleIdentifier)
        playing = try c.decodeIfPresent(Bool.self, forKey: .playing)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        elapsedTime = try c.decodeIfPresent(Double.self, forKey: .elapsedTime)
        if let raw = try c.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = Self.timestampFormatter.date(from: raw)
        } else {
            timestamp = nil
        }
        artworkMimeType = try c.decodeIfPresent(String.self, forKey: .artworkMimeType)
        artworkData = try c.decodeIfPresent(String.self, forKey: .artworkData)
    }

    init(processIdentifier: Int? = nil, bundleIdentifier: String? = nil,
         parentApplicationBundleIdentifier: String? = nil, playing: Bool? = nil,
         title: String? = nil, artist: String? = nil, album: String? = nil,
         duration: Double? = nil, elapsedTime: Double? = nil, timestamp: Date? = nil,
         artworkMimeType: String? = nil, artworkData: String? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.parentApplicationBundleIdentifier = parentApplicationBundleIdentifier
        self.playing = playing
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.artworkMimeType = artworkMimeType
        self.artworkData = artworkData
    }

    /// The adapter encodes `NSDate` as whole-second UTC with a literal `Z`
    /// suffix (`yyyy-MM-dd'T'HH:mm:ss'Z'` — see `sanitizeValueForJsonEncoding`
    /// in the vendored `src/utility/helpers.m`), *not* fractional-second
    /// ISO 8601. `ISO8601DateFormatter` and `Date`'s default JSON decoding
    /// strategies don't reliably match that, so this is a bespoke formatter
    /// mirroring the exact upstream format string.
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}

extension NowPlayingState {
    /// Builds a display-ready snapshot from one (already fully-merged, not a
    /// raw diff fragment) adapter payload. `MediaRemoteAdapterSource` is
    /// responsible for folding `stream`'s partial diff updates into a
    /// complete payload before calling this; this initializer has no notion
    /// of "partial" and treats every field at face value.
    ///
    /// Returns `nil` when the payload doesn't describe anything worth
    /// showing — the adapter's own mandatory-key contract for a valid
    /// "now playing" item is `bundleIdentifier`/`playing`/`title`, but a
    /// missing `title` is the one condition Flux truly can't render around,
    /// so that's the sole hard requirement here. `isPlaying` falls back to
    /// `false` (rather than failing the whole decode) since `playing` can be
    /// legitimately absent from a payload that hasn't changed since an
    /// earlier line already established it — by the time this initializer
    /// runs the caller should have merged that earlier value in, but staying
    /// lenient here means a decode never throws away real metadata over one
    /// missing flag.
    init?(payload: MediaRemoteAdapterPayload) {
        guard let title = payload.title, !title.isEmpty else { return nil }
        self.title = title
        artist = payload.artist
        album = payload.album
        duration = payload.duration
        elapsed = payload.elapsedTime
        isPlaying = payload.playing ?? false
        artworkData = payload.artworkData.flatMap { Data(base64Encoded: $0) }
        sourceBundleID = payload.bundleIdentifier
        timestamp = payload.timestamp ?? Date()
    }
}
