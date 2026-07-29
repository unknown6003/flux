import Combine
import Foundation
import OSLog

/// Shared logger for the whole Now Playing service layer. Created locally
/// (per-subsystem, like every other corner of Flux) rather than added to
/// `Support/Log.swift`, since this module is meant to be self-contained and
/// independently vendorable/removable.
let nowPlayingLog = Logger(subsystem: "com.flux.menubar", category: "nowPlaying")

/// Reads (and controls) system-wide Now Playing metadata via the vendored
/// `mediaremote-adapter` (see `Vendor/mediaremote-adapter/PROVENANCE.md`):
/// a Perl script that dynamically loads a small Objective-C framework from
/// inside `/usr/bin/perl` — a binary Apple's Apple Event / MediaRemote
/// entitlement machinery treats as `com.apple.perl`, which is still allowed
/// to talk to the private MediaRemote framework even on macOS 15.4+, where
/// Apple cut normal app processes off from it entirely.
///
/// Two independent things happen through this one script:
///   - `stream` (long-running, this class's main job): spawned once via
///     `start()` and left running for the app's lifetime; it prints one JSON
///     line per now-playing update until sent SIGTERM.
///   - `send <id>` / `seek <micros>` (one-shot): the adapter genuinely
///     supports *sending* MediaRemote commands, not just reading — see
///     `send(_:)` below — this is the sole transport-control channel;
///     `NowPlayingService` treats an unavailable adapter as nothing playing
///     rather than falling back to a second source (M11 removed the
///     AppleScript-based fallback that used to exist for exactly that case).
@MainActor
final class MediaRemoteAdapterSource {

    private let stateSubject = CurrentValueSubject<NowPlayingState?, Never>(nil)
    var statePublisher: AnyPublisher<NowPlayingState?, Never> { stateSubject.eraseToAnyPublisher() }

    /// True once the `stream` process has been launched and hasn't since
    /// died. This reflects "the process is alive", not "MediaRemote access is
    /// confirmed working" — the vendored adapter also ships a `test` command
    /// backed by a separate `MediaRemoteAdapterTestClient` executable for a
    /// more authoritative liveness probe, but Flux doesn't currently bundle
    /// that executable (see PROVENANCE.md), so a future OS lockdown that
    /// leaves the process running but silent wouldn't flip this to `false`.
    private(set) var isAvailable = false

    private var process: Process?
    private var stdout: Pipe?
    private var lineBuffer = Data()

    /// The latest fully-merged payload dictionary, kept as loose JSON
    /// (`[String: Any]`) rather than a typed struct specifically so `stream`'s
    /// diff semantics can be applied correctly: a `Codable` struct with
    /// optional properties can't distinguish "key absent from this JSON line"
    /// (leave the field as it was) from "key present with a null value"
    /// (clear the field) — `decodeIfPresent` treats both as `nil`. Merging at
    /// the dictionary level preserves that distinction; only once a line has
    /// been folded in do we round-trip the result through
    /// `MediaRemoteAdapterPayload` to get a typed snapshot.
    private var mergedPayload: [String: Any] = [:]

    /// Artwork is tracked separately from `mergedPayload` and only
    /// re-base64-decoded when the *raw* value actually changes. This matters
    /// because upstream's own diffing already suppresses re-sending artwork
    /// that hasn't changed (see PROVENANCE.md), so in steady playback
    /// (elapsed-time ticks, play/pause) the `artworkData` key is simply
    /// absent from most lines — this cache just needs to not throw away the
    /// decoded bytes when that happens, and to actually decode when the key
    /// legitimately reappears with a new value.
    ///
    /// Change detection is done via a cheap fingerprint (the base64 string's
    /// `count` + `hashValue`) rather than retaining the base64 string itself
    /// — artwork payloads can be tens/hundreds of KB, and holding onto that
    /// full string just to `!=`-compare it against the next line would double
    /// this source's memory footprint for artwork it already has decoded
    /// bytes for in `cachedArtworkData`.
    private struct ArtworkFingerprint: Equatable {
        let count: Int
        let hash: Int
    }
    private var cachedArtworkFingerprint: ArtworkFingerprint?
    private var cachedArtworkData: Data?

    private let frameworkPath: String?
    private let scriptPath: String?

    init() {
        (frameworkPath, scriptPath) = Self.resolvePaths()
    }

    deinit {
        restartTask?.cancel()
        stdout?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        guard let frameworkPath, let scriptPath else {
            nowPlayingLog.notice(
                "MediaRemoteAdapter.framework/perl script not bundled (dev build without a built framework?) — Now Playing adapter unavailable")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [scriptPath, frameworkPath, "stream"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        // Upstream: "every line printed to stderr is an error message... if
        // the script did not exit with a non-zero exit code, these are
        // non-fatal and can be safely ignored" — so stderr is discarded
        // rather than parsed; a dead process is detected via terminationHandler.
        proc.standardError = FileHandle.nullDevice

        // Foundation invokes `readabilityHandler` on an internal background
        // queue, never the main thread — hop back explicitly before touching
        // any state, since this whole source is main-actor-isolated.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try proc.run()
            process = proc
            stdout = outPipe
            isAvailable = true
            launchedAt = Date()
        } catch {
            nowPlayingLog.error("Failed to launch mediaremote-adapter stream: \(error.localizedDescription)")
            // Tear the handlers down BEFORE scheduling anything. They were
            // installed above, in anticipation of a launch that then didn't
            // happen, and `stdout`/`process` were never assigned — so neither
            // `stop()` nor `handleTermination()` can ever reach them, and the
            // pipe's read end goes to EOF the moment `outPipe` falls out of
            // scope. A `readabilityHandler` left on an EOF descriptor wakes
            // in a tight loop forever (`availableData` empty every time,
            // which the closure's own emptiness guard silently absorbs). One
            // leaked spinner was bad; the retry below would have made it four
            // on exactly the permanently-broken-perl box the retry exists for.
            outPipe.fileHandleForReading.readabilityHandler = nil
            proc.terminationHandler = nil

            // A launch that never happened produces no process, so no
            // `terminationHandler` will ever fire and nothing downstream
            // would schedule a retry — one transient failure (a momentarily
            // unavailable /usr/bin/perl, a sandbox hiccup) used to kill Now
            // Playing for the rest of the session. Route it through the same
            // bounded backoff as an unexpected exit.
            scheduleRestartIfAllowed()
        }
    }

    func stop() {
        // Cancelled unconditionally, before the `process == nil` bail below:
        // a stop arriving *between* an unexpected exit and its scheduled
        // restart has no process to tear down, but it absolutely must stop
        // that restart from relaunching the helper after the owner asked for
        // it to be off.
        //
        // The attempt count is cleared here too, but do NOT rely on that as
        // the recovery route: nothing in the app currently calls this method
        // at all (`NowPlayingService` deliberately leaves the stream running
        // while inactive). Recovering an exhausted budget is
        // `handleTermination()`'s credit-on-survival, not this.
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        launchedAt = nil

        guard let process else { return }
        stdout?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        stdout = nil
        resetAccumulatedState()
        isAvailable = false
        stateSubject.send(nil)
    }

    /// The adapter genuinely supports sending commands (not just reading),
    /// via one-shot `send <id>` / `seek <micros>` invocations of the same
    /// script — each spawns and exits on its own, independent of the
    /// long-running `stream` process. Command IDs are `MRACommand` from the
    /// vendored `include/MediaRemoteAdapter.h`.
    func send(_ command: NowPlayingCommand) {
        guard frameworkPath != nil, scriptPath != nil else { return }
        switch command {
        case .play: runOneShot(["send", "0"])
        case .pause: runOneShot(["send", "1"])
        case .togglePlayPause: runOneShot(["send", "2"])
        case .next: runOneShot(["send", "4"])
        case .previous: runOneShot(["send", "5"])
        case .seek(let seconds):
            let micros = max(0, Int((seconds * 1_000_000).rounded()))
            runOneShot(["seek", String(micros)])
        }
    }

    // MARK: - One-shot command processes

    private func runOneShot(_ arguments: [String]) {
        guard let frameworkPath, let scriptPath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [scriptPath, frameworkPath] + arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Do NOT wait — `adapter_send`/`adapter_seek` block internally for
            // up to ~2s waiting for MediaRemote's acknowledgement before the
            // process exits on its own; waiting here would stall the caller
            // for no benefit (same fire-and-forget pattern as UpdateChecker's
            // detached swap helper).
        } catch {
            nowPlayingLog.error("Failed to send Now Playing command \(arguments): \(error.localizedDescription)")
        }
    }

    // MARK: - Stream line parsing

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let diff = object["diff"] as? Bool,
              let payload = object["payload"] as? [String: Any]
        else {
            return
        }
        applyPayload(payload, diff: diff)
    }

    /// Folds one `stream` line into the running merged state (see
    /// `mergedPayload`'s doc comment for why this happens at the dictionary
    /// level), then republishes a typed `NowPlayingState`.
    private func applyPayload(_ payload: [String: Any], diff: Bool) {
        if diff {
            for (key, value) in payload where key != "artworkData" {
                if value is NSNull {
                    mergedPayload.removeValue(forKey: key)
                } else {
                    mergedPayload[key] = value
                }
            }
        } else {
            var replacement = payload
            replacement.removeValue(forKey: "artworkData")
            mergedPayload = replacement
        }

        applyArtwork(from: payload, isFullSnapshot: !diff)
        publish()
    }

    private func applyArtwork(from payload: [String: Any], isFullSnapshot: Bool) {
        if let raw = payload["artworkData"] {
            if let base64 = raw as? String, !base64.isEmpty {
                let fingerprint = ArtworkFingerprint(count: base64.count, hash: base64.hashValue)
                if fingerprint != cachedArtworkFingerprint {
                    cachedArtworkFingerprint = fingerprint
                    cachedArtworkData = Data(base64Encoded: base64)
                }
            } else {
                // Explicit null (diff clearing it) or an unexpected type.
                cachedArtworkFingerprint = nil
                cachedArtworkData = nil
            }
        } else if isFullSnapshot {
            // A full snapshot with no artworkData key at all means "no
            // artwork for this item" — unlike a diff line, absence here is
            // authoritative, not "unchanged".
            cachedArtworkFingerprint = nil
            cachedArtworkData = nil
        }
    }

    private func publish() {
        guard JSONSerialization.isValidJSONObject(mergedPayload),
              let data = try? JSONSerialization.data(withJSONObject: mergedPayload),
              let payload = try? JSONDecoder().decode(MediaRemoteAdapterPayload.self, from: data),
              var state = NowPlayingState(payload: payload)
        else {
            stateSubject.send(nil)
            return
        }
        state.artworkData = cachedArtworkData
        stateSubject.send(state)
    }

    /// Consecutive UNEXPECTED exits since the last explicit `stop()`. Bounds
    /// the restart loop below, so a permanently-broken adapter (an OS update
    /// that locks MediaRemote down, a missing perl) retries a few times and
    /// then stays quiet rather than relaunching a doomed subprocess forever.
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?
    private static let maxRestartAttempts = 3

    /// When the current process was launched, or `nil` when none is running.
    /// Read once, at termination, to decide whether that run counts as having
    /// worked — see `handleTermination()`.
    private var launchedAt: Date?

    /// How long a restarted stream must stay up before its restart counts as
    /// having worked. Comfortably longer than the 2/4/8s backoff, so a
    /// crash-loop can never satisfy it.
    private static let healthyUptime: TimeInterval = 30

    /// The stream subprocess died on its own. `stop()` clears
    /// `terminationHandler` before terminating, so reaching here always means
    /// an *unexpected* exit — the owner still wants Now Playing running.
    ///
    /// Nothing used to retry, and nothing else would: `NowPlayingService.
    /// setActive(true)` is `start()`'s only caller and it's guarded on the
    /// active flag actually changing, so a widget that was already open never
    /// re-armed it. One perl/MediaRemote hiccup therefore left the panel
    /// stuck on "Nothing playing" until the user happened to swipe to another
    /// widget and back. A bounded, backing-off restart fixes that without
    /// turning a hard failure into a hot loop.
    private func handleTermination() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdout = nil

        // Credit the run that just ended, if it lasted. The budget counts
        // CONSECUTIVE failed restarts, so it has to clear once a restart has
        // demonstrably worked — `stop()` alone can't do that, since
        // `NowPlayingService` deliberately leaves the stream running while
        // inactive and may never call it, and three unrelated exits across
        // days of uptime would otherwise exhaust it (Codex PR13 finding).
        //
        // Judged on SURVIVAL, not on output, and evaluated here rather than
        // when bytes arrive. Two earlier placements were both wrong: crediting
        // on the first byte removed the bound entirely (a helper that prints
        // one line then dies would reset the budget on every relaunch,
        // spawning a perl process every 2s forever), and crediting from
        // `consume` on an uptime threshold never fired at all — the adapter
        // only prints when now-playing info *changes*, so on an idle Mac it
        // emits once in the first second and then stays silent for hours,
        // never re-entering `consume` past the threshold. Uptime at death is
        // data-independent and still bounds a crash loop, since a doomed run
        // dies far inside `healthyUptime`.
        if let launchedAt, Date().timeIntervalSince(launchedAt) > Self.healthyUptime {
            restartAttempts = 0
        }
        // No run is in flight once this returns, and `launchedAt` is only
        // meaningful between a successful `run()` and its matching
        // termination. (This deliberately does NOT say anything about
        // `consume` — crediting from there was removed as wrong, for the
        // reason given just above, and a comment implying otherwise would
        // invite someone to put it back.)
        launchedAt = nil
        resetAccumulatedState()
        isAvailable = false
        stateSubject.send(nil)

        scheduleRestartIfAllowed()
    }

    /// Schedules the next bounded, backing-off restart, or gives up.
    ///
    /// Shared by the unexpected-exit path and the launch-failure path — both
    /// mean "the helper isn't running and nobody asked for that".
    private func scheduleRestartIfAllowed() {
        guard restartAttempts < Self.maxRestartAttempts else {
            // Deliberately not "until Now Playing is reopened": `stop()` is
            // what would reset the budget, and nothing in the app calls it
            // (`NowPlayingService` leaves the stream running while inactive).
            // Recovery comes from the credit-at-death path above instead.
            nowPlayingLog.error(
                "mediaremote-adapter stream failed repeatedly — no further automatic restarts this session")
            return
        }
        restartAttempts += 1
        let attempt = restartAttempts
        nowPlayingLog.notice(
            "mediaremote-adapter stream unavailable — restarting (attempt \(attempt, privacy: .public))")
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            // 2s, 4s, 8s: long enough that a system briefly refusing to launch
            // the helper isn't hammered, short enough that a transient blip is
            // invisible to anyone watching the panel.
            try? await Task.sleep(for: .seconds(1 << attempt))
            guard !Task.isCancelled, let self, self.process == nil else { return }
            self.start()
        }
    }

    private func resetAccumulatedState() {
        lineBuffer = Data()
        mergedPayload = [:]
        cachedArtworkFingerprint = nil
        cachedArtworkData = nil
    }

    // MARK: - Bundle resolution

    /// The framework/script are placed by `Scripts/build_app.sh`:
    /// `Contents/Frameworks/MediaRemoteAdapter.framework` and
    /// `Contents/Resources/mediaremote-adapter.pl`. In a `swift run`/debug
    /// build (no app bundle assembled) neither exists, which is a normal,
    /// expected state — not an error — so this returns quietly `nil`.
    private static func resolvePaths() -> (framework: String?, script: String?) {
        guard let frameworksURL = Bundle.main.privateFrameworksURL else { return (nil, nil) }
        let frameworkURL = frameworksURL.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: frameworkURL.path) else { return (nil, nil) }
        guard let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") else {
            return (nil, nil)
        }
        return (frameworkURL.path, scriptPath)
    }
}
