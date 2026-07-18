import Foundation

/// Checked-in JSON fixtures for `MediaRemoteAdapterPayload`/`NowPlayingState`
/// decoding tests (see the plan's `--selftest` verification item: "NowPlayingState
/// decode from checked-in adapter JSON fixture"). This machine can't run macOS,
/// so these aren't a `pbpaste`/pcap capture off a real `stream` invocation —
/// they're hand-derived to match the wire format exactly as documented and as
/// implemented in the pinned vendored source (`Vendor/mediaremote-adapter`,
/// see its `PROVENANCE.md`): the `{"type":"data","diff":Bool,"payload":{...}}`
/// envelope from `src/adapter/stream.m`, the flat key set from
/// `src/adapter/keys.m`/`now_playing.m`, and the whole-second UTC
/// `yyyy-MM-dd'T'HH:mm:ss'Z'` timestamp format from `src/utility/helpers.m`.
/// When this project is next run on real hardware, prefer swapping these for
/// an actual captured line (redact nothing but the artwork bytes, which are
/// fine to keep tiny/synthetic either way).
enum NowPlayingFixtures {
    /// A full (non-diff) `stream` line for a track with artwork — the shape
    /// `MediaRemoteAdapterSource` treats as "replace the whole merged state".
    /// `artworkData` is a real, tiny base64-encoded 1x1 PNG so
    /// `Data(base64Encoded:)` round-trips through an actual image decoder in
    /// tests, not just a decodable-but-meaningless string.
    static let streamFullSnapshotJSON = """
    {"type":"data","diff":false,"payload":{"processIdentifier":501,"bundleIdentifier":"com.apple.Music","playing":true,"title":"Sunday Morning","artist":"The Velvet Underground","album":"Loaded","duration":167.5,"elapsedTime":42.25,"timestamp":"2026-07-18T09:30:00Z","playbackRate":1.0,"artworkMimeType":"image/png","artworkData":"\(tinyPNGBase64)"}}
    """

    /// A diffed `stream` line a moment later: only the playback clock moved
    /// (title/artist/album/artwork are unchanged and therefore *absent*, per
    /// upstream's diffing contract — see `PROVENANCE.md`). Exercises that a
    /// decoder consuming one line in isolation must not treat "absent" as
    /// "cleared"; that's `MediaRemoteAdapterSource`'s merge responsibility,
    /// not `MediaRemoteAdapterPayload`'s.
    static let streamDiffTickJSON = """
    {"type":"data","diff":true,"payload":{"elapsedTime":43.25,"timestamp":"2026-07-18T09:30:01Z"}}
    """

    /// A diffed line reporting playback paused (`playing` flips, nothing
    /// else changed).
    static let streamDiffPauseJSON = """
    {"type":"data","diff":true,"payload":{"playing":false}}
    """

    /// A diffed line where a key is explicitly cleared — `null`, not absent
    /// — e.g. artwork unloading. Distinguishing this from "absent" is exactly
    /// what naive `Codable`-only diff merging gets wrong (`decodeIfPresent`
    /// can't tell "missing key" from "present but null"), which is why
    /// `MediaRemoteAdapterSource` merges at the `[String: Any]` level before
    /// ever handing a fully-merged dictionary to `MediaRemoteAdapterPayload`.
    static let streamDiffClearArtworkJSON = """
    {"type":"data","diff":true,"payload":{"artworkData":null,"artworkMimeType":null}}
    """

    /// Nothing playing: `stream` still emits a full, non-diff envelope, but
    /// with an empty payload dictionary (never `null` itself — only the
    /// one-shot `get` command's top-level result can be the literal `null`).
    static let streamIdleJSON = """
    {"type":"data","diff":false,"payload":{}}
    """

    /// A minimal, real-looking 1x1 transparent PNG, base64-encoded — small
    /// enough to keep this file readable while still exercising a genuine
    /// `Data(base64Encoded:)` decode of image bytes.
    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
