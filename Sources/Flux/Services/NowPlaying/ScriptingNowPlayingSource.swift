import AppKit
import Combine

/// AppleScript-based fallback for Music.app and Spotify — the safety net for
/// when `MediaRemoteAdapterSource` is unavailable (framework didn't bundle,
/// or a future macOS closes the `/usr/bin/perl` loophole entirely). Unlike
/// the adapter, this only ever sees the two scriptable players it explicitly
/// targets, never arbitrary apps (Safari video, Podcasts, etc.).
///
/// `NSAppleScript.executeAndReturnError` is synchronous with no async
/// variant — sending an Apple Event and waiting for the target app's reply
/// can take anywhere from sub-millisecond to hundreds of milliseconds (a
/// stalled/relaunching player, a slow disk read for artwork, ...). To honor
/// "never block the main thread", every compiled script is executed on a
/// private serial background queue (`scriptQueue` — serial so overlapping
/// polls/commands can't reenter the same `NSAppleScript` instance
/// concurrently), and results hop back to the main actor before touching any
/// published state.
///
/// Polling (state only — never artwork, see below) runs at a fixed 2s
/// cadence, and *only* while `start()`-ed; `stop()` invalidates the timer
/// immediately, satisfying the "widget hidden ⇒ scripting poll MUST stop"
/// contract from `NowPlayingService.setActive(_:)`.
@MainActor
final class ScriptingNowPlayingSource: NowPlayingSource {

    private enum PlayerApp: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var scriptingName: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            }
        }
    }

    private enum CommandKind: Hashable {
        case play, pause, toggle, next, previous
    }

    private let stateSubject = CurrentValueSubject<NowPlayingState?, Never>(nil)
    var statePublisher: AnyPublisher<NowPlayingState?, Never> { stateSubject.eraseToAnyPublisher() }

    /// Whether Music or Spotify is currently running at all (independent of
    /// whether it's actually playing) — surfaced for `NowPlayingService`'s
    /// status text.
    private(set) var isAvailable = false
    var activeAppName: String? { activeApp?.scriptingName }

    private var activeApp: PlayerApp?
    private var isStarted = false
    private var pollTimer: Timer?
    private var lastState: NowPlayingState?

    private let scriptQueue = DispatchQueue(label: "com.flux.menubar.nowplaying.applescript", qos: .userInitiated)
    private var stateScripts: [PlayerApp: NSAppleScript] = [:]
    private var commandScripts: [PlayerApp: [CommandKind: NSAppleScript]] = [:]
    private var artworkURLScripts: [PlayerApp: NSAppleScript] = [:]
    private var musicArtworkDataScript: NSAppleScript?

    // Single-slot cache: only ever holds the current track's artwork, never
    // a history, so switching tracks repeatedly can't accumulate memory.
    private var artworkTrackKey: String?
    private var artworkData: Data?
    private var artworkFetchTask: Task<Void, Never>?

    deinit {
        pollTimer?.invalidate()
        artworkFetchTask?.cancel()
    }

    // MARK: - NowPlayingSource

    func start() {
        guard !isStarted else { return }
        isStarted = true
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        activeApp = nil
        isAvailable = false
        lastState = nil
        artworkTrackKey = nil
        artworkData = nil
        stateSubject.send(nil)
    }

    func send(_ command: NowPlayingCommand) {
        guard let app = activeApp ?? Self.detectRunningApp(preferring: nil) else { return }
        switch command {
        case .play: runCommand(.play, on: app)
        case .pause: runCommand(.pause, on: app)
        case .togglePlayPause: runCommand(.toggle, on: app)
        case .next: runCommand(.next, on: app)
        case .previous: runCommand(.previous, on: app)
        case .seek(let seconds): runSeek(seconds, on: app)
        }
    }

    // MARK: - Polling

    private func poll() {
        guard isStarted else { return }
        guard let app = Self.detectRunningApp(preferring: activeApp) else {
            activeApp = nil
            isAvailable = false
            lastState = nil
            artworkTrackKey = nil
            artworkData = nil
            stateSubject.send(nil)
            return
        }
        isAvailable = true
        activeApp = app
        let script = stateScript(for: app)
        scriptQueue.async { [weak self] in
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            let rawString = errorInfo == nil ? descriptor.stringValue : nil
            if let errorInfo {
                nowPlayingLog.error("AppleScript state poll failed for \(app.scriptingName, privacy: .public): \(errorInfo)")
            }
            Task { @MainActor in
                self?.handlePollResult(rawString, app: app)
            }
        }
    }

    /// Fields are `|||`-delimited: state | title | artist | album | duration
    /// (seconds) | position (seconds) | a per-track identity key (used only
    /// to detect track changes for artwork re-fetching, never surfaced).
    private func handlePollResult(_ raw: String?, app: PlayerApp) {
        guard isStarted, activeApp == app else { return }
        guard let raw else {
            stateSubject.send(nil)
            return
        }
        let fields = raw.components(separatedBy: "|||")
        guard fields.count == 7, fields[0] != "stopped" else {
            lastState = nil
            artworkTrackKey = nil
            artworkData = nil
            stateSubject.send(nil)
            return
        }

        let title = fields[1]
        guard !title.isEmpty else {
            stateSubject.send(nil)
            return
        }
        let playing = fields[0] == "playing"
        let artist = fields[2].isEmpty ? nil : fields[2]
        let album = fields[3].isEmpty ? nil : fields[3]
        let duration = Double(fields[4])
        let position = Double(fields[5])
        let trackKey = fields[6]

        let state = NowPlayingState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: position,
            isPlaying: playing,
            artworkData: artworkTrackKey == trackKey ? artworkData : nil,
            sourceBundleID: app.rawValue,
            timestamp: Date()
        )
        lastState = state
        stateSubject.send(state)

        if artworkTrackKey != trackKey {
            artworkTrackKey = trackKey
            artworkData = nil
            fetchArtwork(for: app, trackKey: trackKey)
        }
    }

    // MARK: - Artwork

    private func fetchArtwork(for app: PlayerApp, trackKey: String) {
        artworkFetchTask?.cancel()
        artworkFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let data: Data?
            switch app {
            case .spotify:
                data = await self.fetchSpotifyArtwork()
            case .music:
                data = await self.fetchMusicArtworkData()
            }
            guard !Task.isCancelled, self.artworkTrackKey == trackKey else { return }
            self.artworkData = data
            guard var refreshed = self.lastState, refreshed.sourceBundleID == app.rawValue else { return }
            refreshed.artworkData = data
            self.lastState = refreshed
            self.stateSubject.send(refreshed)
        }
    }

    /// Spotify exposes a plain artwork URL — fetch it like any other image.
    private func fetchSpotifyArtwork() async -> Data? {
        guard let urlString = await runScriptForString(artworkURLScript(for: .spotify)),
              !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            nowPlayingLog.error("Spotify artwork fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Music.app has no artwork URL — the only AppleScript path is the raw
    /// `data of artwork 1 of current track`, which hands back whatever image
    /// bytes the track's embedded/library artwork actually is. This is
    /// best-effort: some encodings AppleScript exposes here aren't anything
    /// `CGImageSource` can decode, in which case `NowPlayingService`'s
    /// downsampling step simply produces `nil` — no crash, just no artwork.
    private func fetchMusicArtworkData() async -> Data? {
        await withCheckedContinuation { continuation in
            let script = musicArtworkScript()
            scriptQueue.async {
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                let data = errorInfo == nil ? descriptor.data : nil
                continuation.resume(returning: (data?.isEmpty == false) ? data : nil)
            }
        }
    }

    private func runScriptForString(_ script: NSAppleScript) async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                continuation.resume(returning: errorInfo == nil ? descriptor.stringValue : nil)
            }
        }
    }

    // MARK: - Commands

    private func runCommand(_ kind: CommandKind, on app: PlayerApp) {
        let script = commandScript(kind, for: app)
        scriptQueue.async {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                nowPlayingLog.error("AppleScript command \(String(describing: kind)) failed on \(app.scriptingName, privacy: .public): \(errorInfo)")
            }
        }
    }

    private func runSeek(_ seconds: TimeInterval, on app: PlayerApp) {
        // Unlike the fixed-verb commands, a seek target is a one-off numeric
        // argument. `NSAppleScript` has no clean way to parameterize a
        // compiled script, so this compiles fresh per call — acceptable
        // since seeks are rare, user-initiated actions, not part of the 2s
        // poll loop.
        let clamped = max(0, seconds)
        let source = "tell application \"\(app.scriptingName)\" to set player position to \(clamped)"
        guard let script = NSAppleScript(source: source) else { return }
        scriptQueue.async {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                nowPlayingLog.error("AppleScript seek failed on \(app.scriptingName, privacy: .public): \(errorInfo)")
            }
        }
    }

    // MARK: - Compiled script cache

    private func stateScript(for app: PlayerApp) -> NSAppleScript {
        if let cached = stateScripts[app] { return cached }
        let name = app.scriptingName
        // Spotify reports track duration in milliseconds; Music in seconds.
        // Normalizing inside the script keeps the Swift-side parsing uniform.
        let durationExpr = app == .spotify ? "(duration of current track) / 1000.0" : "duration of current track"
        let source = """
        tell application "\(name)"
            if player state is stopped then return "stopped"
            set st to player state as string
            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
            set dur to \(durationExpr)
            set pos to player position
            set tid to (id of current track) as string
            return st & "|||" & trackName & "|||" & artistName & "|||" & albumName & "|||" & (dur as string) & "|||" & (pos as string) & "|||" & tid
        end tell
        """
        let script = NSAppleScript(source: source)!
        stateScripts[app] = script
        return script
    }

    private func commandScript(_ kind: CommandKind, for app: PlayerApp) -> NSAppleScript {
        if let cached = commandScripts[app]?[kind] { return cached }
        let verb: String
        switch kind {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        let source = "tell application \"\(app.scriptingName)\" to \(verb)"
        let script = NSAppleScript(source: source)!
        commandScripts[app, default: [:]][kind] = script
        return script
    }

    private func artworkURLScript(for app: PlayerApp) -> NSAppleScript {
        if let cached = artworkURLScripts[app] { return cached }
        let source = """
        tell application "\(app.scriptingName)"
            if player state is stopped then return ""
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """
        let script = NSAppleScript(source: source)!
        artworkURLScripts[app] = script
        return script
    }

    private func musicArtworkScript() -> NSAppleScript {
        if let cached = musicArtworkDataScript { return cached }
        let source = """
        tell application "Music"
            if player state is stopped then return ""
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        let script = NSAppleScript(source: source)!
        musicArtworkDataScript = script
        return script
    }

    // MARK: - App detection

    private static func isRunning(_ app: PlayerApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.rawValue).isEmpty
    }

    /// Sticks with `preferring` (the currently-tracked app) if it's still
    /// running, so a session doesn't flip-flop between Music and Spotify
    /// when both happen to be open; otherwise picks whichever of the two is
    /// running, Music first.
    private static func detectRunningApp(preferring: PlayerApp?) -> PlayerApp? {
        if let preferring, isRunning(preferring) { return preferring }
        return PlayerApp.allCases.first(where: isRunning)
    }
}
