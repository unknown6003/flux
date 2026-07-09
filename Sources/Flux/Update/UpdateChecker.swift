import AppKit
import Combine

/// A tiny, zero-dependency over-the-air updater built on the GitHub Releases API.
///
/// It polls `releases/latest`, compares the published tag against the running
/// build, and — only when the user asks — downloads the release DMG and hands it
/// to Finder to mount. There is no Sparkle, no privileged helper, no auto-replace
/// of the app bundle: staying in the same zero-permission spirit as the rest of
/// Flux. The network step is a plain HTTPS GET; nothing installs without a click.
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
        case readyToInstall(URL)   // the downloaded DMG, now mounted for the user
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// When the last check finished (any outcome) — drives the "Last checked" line.
    @Published private(set) var lastChecked: Date?

    private let currentVersion: String
    private var isBusy = false

    init(currentVersion: String = AppInfo.version) {
        self.currentVersion = currentVersion
    }

    // MARK: - Checking

    /// Poll GitHub and compare against the running build. `userInitiated` decides
    /// how loud the result is: a manual check shows "up to date" and surfaces
    /// errors; a background check stays silent unless it finds something newer.
    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        // Never interrupt an in-flight download or a ready-to-install DMG.
        switch state {
        case .downloading: return
        case .readyToInstall where !userInitiated: return
        default: break
        }
        isBusy = true
        if userInitiated { state = .checking }
        Task { await runCheck(userInitiated: userInitiated) }
    }

    private func runCheck(userInitiated: Bool) async {
        defer { isBusy = false }
        do {
            let release = try await fetchLatest()
            lastChecked = Date()
            if let release, isNewer(release.version, than: currentVersion) {
                state = .available(release)
                Log.menuBar.info("Update available: \(release.version) (running \(self.currentVersion))")
            } else if userInitiated {
                state = .upToDate
            } else if case .available = state {
                state = .idle   // a previously-seen release was pulled
            }
        } catch {
            lastChecked = Date()
            Log.menuBar.error("Update check failed: \(error.localizedDescription)")
            if userInitiated { state = .failed(Self.friendly(error)) }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: Self.releasesURL)
        request.timeoutInterval = 15
        // GitHub rejects API requests without a User-Agent (HTTP 403).
        request.setValue("Flux/\(currentVersion) (macOS; +https://github.com/unknown6003/flux)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
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

    /// Download the release DMG (user-initiated) and open it in Finder so the user
    /// can drag Flux to Applications — the standard non-Sparkle handoff. If the
    /// release carries no DMG, fall back to opening its page in the browser.
    func downloadAndInstall(_ release: Release) {
        guard !isBusy else { return }
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        isBusy = true
        state = .downloading
        Task { await runDownload(release, dmgURL: dmgURL) }
    }

    private func runDownload(_ release: Release, dmgURL: URL) async {
        defer { isBusy = false }
        do {
            var request = URLRequest(url: dmgURL)
            request.timeoutInterval = 120
            request.setValue("Flux/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let dest = try moveToDownloads(tempURL, suggested: dmgURL.lastPathComponent,
                                           version: release.version)
            state = .readyToInstall(dest)
            NSWorkspace.shared.open(dest)   // mount the DMG for the user
            Log.menuBar.info("Downloaded update \(release.version) → \(dest.path)")
        } catch {
            Log.menuBar.error("Update download failed: \(error.localizedDescription)")
            state = .failed(Self.friendly(error))
        }
    }

    /// The async `download(for:)` temp file is reaped when this returns, so move it
    /// into ~/Downloads first. Never clobbers an existing file of the same name.
    private func moveToDownloads(_ temp: URL, suggested: String, version: String) throws -> URL {
        let fm = FileManager.default
        let downloads = try fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let name = suggested.lowercased().hasSuffix(".dmg") ? suggested : "Flux-\(version).dmg"
        var dest = downloads.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            let stem = dest.deletingPathExtension().lastPathComponent
            dest = downloads.appendingPathComponent("\(stem)-\(version).dmg")
            try? fm.removeItem(at: dest)
        }
        try fm.moveItem(at: temp, to: dest)
        return dest
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
