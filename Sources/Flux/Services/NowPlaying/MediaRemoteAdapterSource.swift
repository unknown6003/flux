import Combine
import Foundation

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
///     `send(_:)` below — so this is the primary transport-control channel;
///     `ScriptingNowPlayingSource`'s AppleScript commands are the fallback,
///     used only when this adapter is unavailable.
@MainActor
final class MediaRemoteAdapterSource: NowPlayingSource {

    private let stateSubject = CurrentValueSubject<NowPlayingState?, Never>(nil)
    var statePublisher: AnyPublisher<NowPlayingState?, Never> { stateSubject.eraseToAnyPublisher() }

    /// True once the `stream` process has been launched and hasn't since
    /// died. This reflects "the process is alive", not "MediaRemote access is
    /// confirmed working" — the vendored adapter also ships a `test` command
    /// backed by a separate `MediaRemoteAdapterTestClient` executable for a
    /// more authoritative liveness probe, but Flux doesn't currently bundle
    /// that executable (see PROVENANCE.md), so a future OS lockdown that
    /// leaves the process running but silent wouldn't flip this to `false`.
    private(set) var isAvailable = false {
        didSet {
            guard oldValue != isAvailable else { return }
            availabilitySubject.send(isAvailable)
        }
    }

    /// Lets `NowPlayingService` react to availability changes (e.g. to start
    /// the AppleScript fallback) without polling `isAvailable`.
    private let availabilitySubject = CurrentValueSubject<Bool, Never>(false)
    var availabilityPublisher: AnyPublisher<Bool, Never> { availabilitySubject.eraseToAnyPublisher() }

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
        stdout?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    // MARK: - NowPlayingSource

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
        } catch {
            nowPlayingLog.error("Failed to launch mediaremote-adapter stream: \(error.localizedDescription)")
        }
    }

    func stop() {
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

    private func handleTermination() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdout = nil
        resetAccumulatedState()
        isAvailable = false
        stateSubject.send(nil)
        nowPlayingLog.notice("mediaremote-adapter stream process exited — Now Playing adapter unavailable")
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
