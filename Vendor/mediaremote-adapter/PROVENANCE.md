# Provenance — mediaremote-adapter

Vendored from the upstream project that works around Apple's macOS 15.4+
MediaRemote lockdown by loading a small Objective-C framework from inside
`/usr/bin/perl` (entitled as `com.apple.perl`, so it's allowed to talk to the
private `MediaRemote` framework where a normal app process is refused).

- **Upstream:** https://github.com/ungive/mediaremote-adapter
- **License:** BSD 3-Clause (see `LICENSE` in this folder, copied verbatim)
- **Pinned tag:** `v0.7.6`
- **Pinned commit:** `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`
- **Vendored on:** 2026-07-18

## What's vendored

This is a *source* vendor (upstream ships no prebuilt binary release assets —
only tagged source), built by our own tooling:

- `bin/mediaremote-adapter.pl` — the Perl entry point Flux spawns. Invoked as:
  `/usr/bin/perl mediaremote-adapter.pl <FRAMEWORK_PATH> <get|stream|send|seek|...>`
- `CMakeLists.txt`, `include/`, `src/` — the Objective-C source for
  `MediaRemoteAdapter.framework` (and an upstream `MediaRemoteAdapterTestClient`
  target that Flux does not currently bundle or use — see below).

Not vendored: `README.md`, `Makefile`, `scripts/`, `.clang-format`,
`.cmake-format`, `.perltidyrc`, `.vscode/` — none of these are needed to build
or run the framework/script; they're upstream dev tooling.

`src/test/` (`MediaRemoteAdapterTestClient`) is vendored because dropping it
would require patching `CMakeLists.txt` (which unconditionally declares that
target), but Flux does not currently invoke the `test` command or bundle the
resulting executable — liveness is instead inferred from the `stream` process
dying or going quiet (see `MediaRemoteAdapterSource.swift`). A future change
could bundle it under `Contents/Resources/` and use the `test` command for a
more authoritative "is the adapter still functional" probe.

## The interface Flux depends on (verified against this pinned source)

`/usr/bin/perl <script> <FRAMEWORK_PATH> <COMMAND> [args] [options]`

- `stream` — long-running; prints one JSON line per update to stdout until it
  receives SIGTERM. Each line is `{"type":"data","diff":Bool,"payload":{...}}`.
  When `diff` is `true`, `payload` contains only changed keys (present-with-a-
  value = updated, present-with-`null` = removed, absent = unchanged from the
  last full/diff state); consumers must maintain the merged state themselves.
  When `diff` is `false`, `payload` is the complete current state (or `{}`
  when nothing is playing). Diffing is on by default; we don't pass
  `--no-diff` since Flux's `MediaRemoteAdapterSource` merges diffs itself.
- `send <ID>` — one-shot process; sends a MediaRemote command
  (0=play, 1=pause, 2=toggle, 3=stop, 4=next, 5=previous, 6=toggle shuffle,
  7=toggle repeat, 8-11=seek-gesture start/end, 12=back 15s, 13=fwd 15s).
  Exit code reflects success/failure; blocks internally up to ~2s waiting for
  MediaRemote to acknowledge, then the process exits. See `send.m` /
  `MediaRemoteAdapter.h`'s `MRACommand` enum.
- `seek <MICROSECONDS>` — one-shot process; sets the playback position.
- The adapter genuinely supports *sending* commands, not just reading — this
  is the mechanism `MediaRemoteAdapterSource.send(_:)` uses directly, and (as
  of M11) the sole Now Playing command channel — Flux no longer ships an
  AppleScript fallback for when the adapter is unavailable/dead.

Payload keys actually observed in the vendored source (`src/adapter/keys.m`,
`src/adapter/now_playing.m`) that Flux's `MediaRemoteAdapterPayload` decodes:
`processIdentifier` (Int), `bundleIdentifier` (String), `playing` (Bool),
`title` (String), `artist`/`album` (String?), `duration`/`elapsedTime`
(Double seconds), `timestamp` (String, `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC —
*not* fractional-second ISO 8601, see `sanitizeValueForJsonEncoding` in
`src/utility/helpers.m`), `artworkMimeType` (String), `artworkData` (String,
base64, from `NSData.base64EncodedStringWithOptions:`). All other documented
keys (chapter/genre/queue/etc.) are ignored by Flux for now.

## How to update

1. `git clone https://github.com/ungive/mediaremote-adapter.git /tmp/mra && cd /tmp/mra`
2. Pick a tag, note its commit: `git log -1 --format='%H'`.
3. Re-copy `bin/mediaremote-adapter.pl`, `CMakeLists.txt`, `include/`, `src/`
   (all four subfolders) over this directory.
4. Diff `src/adapter/keys.m`, `src/adapter/now_playing.m`, and the README's
   `## stream` / `## send COMMAND` / `## seek POSITION` sections against what's
   above — if the JSON schema or command IDs changed, update
   `Sources/Flux/Services/NowPlaying/NowPlayingState.swift` (the
   `MediaRemoteAdapterPayload` struct and `NowPlayingCommand` → ID mapping in
   `MediaRemoteAdapterSource.swift`) to match, and refresh
   `NowPlayingFixtures.swift`.
5. Update the pinned tag/commit/date in this file.
6. Run `Scripts/build_app.sh` on a Mac (or via CI) to confirm the framework
   still builds and the app still passes `--selftest`.
