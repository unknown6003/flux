import AppKit
import Combine

/// A tiny, zero-dependency over-the-air updater built on the GitHub Releases API.
///
/// It checks `releases/latest` and prepares the newer app beside the installed
/// bundle. A detached helper replaces it after Flux quits, then relaunches.
/// A location that needs admin permission requires a manual install from Downloads.
@MainActor
final class UpdateChecker: ObservableObject {

    /// GitHub returns the newest non-draft, non-prerelease release for the repo.
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/unknown6003/flux/releases/latest")!

    /// A newer release Flux found on GitHub, distilled to what the UI needs.
    struct Release: Equatable {
        let version: String        // normalized — no leading "v"
        let name: String           // release title, e.g. "Flux 0.2.0"
        let notes: String          // release body (markdown), trimmed
        let pageURL: URL           // the release's html_url — the fallback target
        let dmgURL: URL?           // the .dmg asset, if the release ships one
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing            // swapping the bundle in place; app will relaunch
        case readyToInstall(URL)   // fallback: the downloaded DMG for a manual drag-install
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// When the last check finished (any outcome) — drives the "Last checked" line.
    @Published private(set) var lastChecked: Date?

    private let currentVersion: String
    private let session: URLSession
    private let releaseURL: URL
    private let installURL: URL
    private let downloadsURL: URL?
    private var cachedDownload: (version: String, source: URL, file: URL)?
    private let terminate: @MainActor () -> Void
    private var isBusy = false

    /// Set when a user-initiated check arrives while a background one is
    /// already in flight. The in-flight check then reports its result at
    /// user-initiated loudness — without this, adopting its spinner (see
    /// `checkForUpdates`) would strand the UI on `.checking` forever, since
    /// a quiet check's "nothing new" branch deliberately writes no state.
    private var pendingUserInitiated = false

    init(currentVersion: String = AppInfo.version,
         session: URLSession? = nil,
         releaseURL: URL? = nil,
         installURL: URL = Bundle.main.bundleURL,
         downloadsURL: URL? = nil,
         terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.currentVersion = currentVersion
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration)
        self.releaseURL = releaseURL ?? Self.releasesURL
        self.installURL = installURL
        self.downloadsURL = downloadsURL
        self.terminate = terminate
    }

    /// Whether `state` is currently advertising a newer release — the one
    /// question the menu bar needs to answer, without every caller having to
    /// pattern-match `State` themselves.
    var pendingRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Clears outcomes that were true once and aren't necessarily true now.
    /// Called when Settings opens, since that's the only place they render.
    ///
    /// `.failed` and `.readyToInstall` used to be sticky for the process's
    /// whole life: Settings reopened days later still showed "No internet
    /// connection." from a check made on a train, or offered to install a DMG
    /// the user had long since deleted from ~/Downloads. `.upToDate` is
    /// cleared for the same reason — it's an answer about a moment, not a
    /// standing fact, and the "Check for Updates" button returning is the
    /// honest state for a window opened later. (Note this does mean opening
    /// Settings again right after a manual check drops the tick; that is the
    /// intended trade, since the alternative is showing a days-old verdict.)
    /// `.available` is deliberately NOT cleared — that one stays true until a
    /// check says otherwise, and it's the whole point of the background poll.
    func clearStaleOutcome() {
        switch state {
        case .failed, .upToDate:
            state = .idle
        case .readyToInstall(let url):
            if !FileManager.default.fileExists(atPath: url.path) { state = .idle }
        default:
            break
        }
    }

    // MARK: - Checking

    /// Background checks may install only a release that includes the same DMG
    /// asset the release workflow publishes. Manual checks keep their explicit
    /// click-to-install behavior.
    static func shouldAutomaticallyInstall(userInitiated: Bool,
                                            release: Release) -> Bool {
        !userInitiated && release.dmgURL != nil
    }

    /// Poll GitHub and compare against the running build. `userInitiated` decides
    /// how loud the result is: a manual check shows "up to date" and surfaces
    /// errors; a background check stays silent unless it finds something newer.
    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else {
            // A background check is already running (the launch check fires
            // 4s in), and it left `state` at `.idle` — so the Settings card
            // still showed its "Check for Updates" button, and pressing it
            // returned here with no visual change whatsoever. Adopting the
            // in-flight check's spinner is honest: the answer the user asked
            // for is genuinely on its way.
            if userInitiated {
                switch state {
                case .downloading, .installing: break
                default:
                    pendingUserInitiated = true
                    state = .checking
                }
            }
            return
        }
        // Keep active downloads and installs intact. A later background check
        // can retry a manual fallback if the install location becomes writable.
        switch state {
        case .downloading, .installing: return
        default: break
        }
        isBusy = true
        if userInitiated { state = .checking }
        Task { await runCheck(userInitiated: userInitiated) }
    }

    /// `pendingUserInitiated` is read at RESULT time, not on entry: the user
    /// can press "Check for Updates" at any point while this is awaiting the
    /// network, and the loudness of the outcome has to account for that.
    private func runCheck(userInitiated requested: Bool) async {
        defer {
            isBusy = false
            pendingUserInitiated = false
        }
        do {
            let release = try await fetchLatest()
            let userInitiated = requested || pendingUserInitiated
            lastChecked = Date()
            if let release, isNewer(release.version, than: currentVersion) {
                state = .available(release)
                Log.menuBar.info("Update available: \(release.version) (running \(self.currentVersion))")
                // A manual refresh can show a background result, but must not
                // cancel the automatic install that started this check.
                if Self.shouldAutomaticallyInstall(userInitiated: requested,
                                                    release: release),
                   let dmgURL = release.dmgURL {
                    await runDownload(release, dmgURL: dmgURL, automatic: true)
                }
            } else if userInitiated {
                state = .upToDate
            } else if case .available = state {
                state = .idle   // a previously-seen release was pulled
            }
        } catch {
            let userInitiated = requested || pendingUserInitiated
            lastChecked = Date()
            Log.menuBar.error("Update check failed: \(error.localizedDescription)")
            if userInitiated { state = .failed(Self.friendly(error)) }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: releaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        // GitHub rejects API requests without a User-Agent (HTTP 403).
        request.setValue("Flux/\(currentVersion) (macOS; +https://github.com/unknown6003/flux)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        // No published release yet → treat as "up to date", not an error.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        let payload = try JSONDecoder().decode(GHRelease.self, from: data)
        guard payload.draft != true, payload.prerelease != true,
              let pageURL = URL(string: payload.htmlURL) else { return nil }

        let dmg = payload.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
        return Release(
            version: Self.normalize(payload.tagName),
            name: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
            notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: pageURL,
            dmgURL: dmg.flatMap { URL(string: $0.browserDownloadURL) }
        )
    }

    // MARK: - Downloading

    /// Download the release DMG (user-initiated) and install it *in place*: mount
    /// the image, swap the new `Flux.app` over the running bundle, and relaunch.
    /// If the install location isn't writable, fall back to opening the DMG for a
    /// manual drag-install. If the release carries no DMG, open its page instead.
    func downloadAndInstall(_ release: Release) {
        guard !isBusy else { return }
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        isBusy = true
        state = .downloading
        Task { await runDownload(release, dmgURL: dmgURL, automatic: false) }
    }

    private func runDownload(_ release: Release, dmgURL: URL, automatic: Bool) async {
        defer { isBusy = false }
        state = .downloading
        do {
            let dmg: URL
            if let cached = cachedDownload, cached.version == release.version, cached.source == dmgURL,
               FileManager.default.fileExists(atPath: cached.file.path) {
                dmg = cached.file
            } else {
                var request = URLRequest(url: dmgURL)
                request.timeoutInterval = 120
                request.setValue("Flux/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (tempURL, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                // The async `download(for:)` temp file is reaped when this returns, so
                // move it to a stable spot we control before mounting/handing off.
                dmg = try stageDownload(tempURL)
            }

            do {
                try await selfInstall(dmgAt: dmg, release: release)
                // selfInstall flips state to .installing and schedules the quit;
                // the detached helper takes over from here.
            } catch UpdateInstaller.Failure.notWritable {
                Log.menuBar.error("Self-install unavailable: install location needs permission")
                let dest: URL
                if cachedDownload?.file == dmg { dest = dmg }
                else { dest = try moveToDownloads(dmg, version: release.version) }
                cachedDownload = (release.version, dmgURL, dest)
                state = .readyToInstall(dest)
                if !automatic {
                    NSWorkspace.shared.open(dest)   // mount the DMG for the user
                }
            }
        } catch {
            Log.menuBar.error("Update download failed: \(error.localizedDescription)")
            state = .failed(Self.friendly(error))
        }
    }

    // MARK: - In-place install

    private func selfInstall(dmgAt dmg: URL, release: Release) async throws {
        let destination = installURL
        let version = release.version
        // Mounting and copying run off the main actor, with process deadlines.
        try await Task.detached(priority: .utility) {
            try UpdateInstaller.prepareAndLaunch(dmg: dmg, installURL: destination,
                                                  version: version)
        }.value
        state = .installing
        Log.menuBar.info("Installing update \(release.version) → relaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.terminate()
        }
    }

    /// Fallback only: park the DMG in ~/Downloads for a manual drag-install.
    /// Never clobbers an existing file of the same name.
    private func moveToDownloads(_ dmg: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let downloads = try downloadsURL ?? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let name = version.filter { $0.isNumber || $0 == "." || $0 == "-" }
        var dest = downloads.appendingPathComponent("Flux-\(name).dmg")
        if fm.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("Flux-\(name)-\(UUID().uuidString).dmg")
        }
        do {
            try fm.moveItem(at: dmg, to: dest)
        } catch {
            try fm.copyItem(at: dmg, to: dest)   // cross-volume safety
            try? fm.removeItem(at: dmg)
        }
        return dest
    }

    /// Move the URLSession download temp file to a stable, app-controlled path so
    /// it survives `runDownload` returning and can be read by the mount subprocess.
    private func stageDownload(_ temp: URL) throws -> URL {
        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent("Flux-update-\(UUID().uuidString).dmg")
        try fm.moveItem(at: temp, to: staged)
        return staged
    }

    // MARK: - Version comparison

    /// True iff `candidate` is a strictly higher semantic version than `current`.
    /// Compares dot-separated numeric components pairwise, padding the shorter
    /// with zeros (so `0.2` > `0.1.9`). Pre-release suffixes are ignored.
    func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = Self.components(candidate), b = Self.components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func normalize(_ tag: String) -> String {
        var v = tag.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    private static func components(_ version: String) -> [Int] {
        // Keep the numeric core, dropping any "-beta.1" / "+build" suffix.
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: - Errors

    private enum UpdateError: LocalizedError {
        case network
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .network: return "Couldn't reach GitHub."
            case .http(let code): return "GitHub returned HTTP \(code)."
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? UpdateError, let d = e.errorDescription { return d }
        if let e = error as? UpdateInstaller.Failure, let d = e.errorDescription { return d }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "The update check timed out."
            default: break
            }
        }
        return "Update check failed. Try again later."
    }

    // MARK: - GitHub API shapes

    private struct GHRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GHAsset]?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, prerelease, assets
            case htmlURL = "html_url"
        }
    }

    private struct GHAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
