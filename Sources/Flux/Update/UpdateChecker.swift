import AppKit
import Combine

/// A tiny, zero-dependency over-the-air updater built on the GitHub Releases API.
///
/// It polls `releases/latest`, compares the published tag against the running
/// build, and — only when the user asks — downloads the release DMG and installs
/// it *in place*: it mounts the image, swaps the new `Flux.app` over the running
/// bundle, and relaunches, so the app is simply the new version when it comes
/// back. This is the Sparkle-style handoff without Sparkle — a small detached
/// shell helper does the swap after we quit (a running bundle can't overwrite
/// itself). No privileged helper is used; if the install location isn't writable
/// (e.g. `/Applications` owned by another admin), it falls back to the old manual
/// path — dropping the DMG in ~/Downloads and opening it for a drag-install.
/// The network step is a plain HTTPS GET; nothing installs without a click.
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
        case readyToInstall(URL)   // fallback: the downloaded DMG, opened for a manual drag-install
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
        // Never interrupt an in-flight download, an install-in-progress, or a
        // ready-to-install DMG.
        switch state {
        case .downloading, .installing: return
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
            // The async `download(for:)` temp file is reaped when this returns, so
            // move it to a stable spot we control before mounting/handing off.
            let dmg = try stageDownload(tempURL, version: release.version)

            do {
                try selfInstall(dmgAt: dmg, release: release)
                // selfInstall flips state to .installing and schedules the quit;
                // the detached helper takes over from here.
            } catch {
                // Couldn't swap in place (e.g. /Applications needs admin). Fall
                // back to the tried-and-true manual drag-install.
                Log.menuBar.error("Self-install unavailable (\(error.localizedDescription)); manual fallback")
                let dest = try moveToDownloads(dmg, version: release.version)
                state = .readyToInstall(dest)
                NSWorkspace.shared.open(dest)   // mount the DMG for the user
            }
        } catch {
            Log.menuBar.error("Update download failed: \(error.localizedDescription)")
            state = .failed(Self.friendly(error))
        }
    }

    // MARK: - In-place install

    /// Mounts the DMG, locates the new app, and hands a detached shell helper the
    /// job of swapping the bundle and relaunching once we've quit — a running
    /// bundle can't reliably overwrite its own executable, so the swap must happen
    /// after termination. Throws (for the manual fallback) if the install location
    /// isn't writable, the image won't mount, or it holds no `.app`.
    private func selfInstall(dmgAt dmg: URL, release: Release) throws {
        let installURL = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: installURL.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable
        }

        let mount = try mountDMG(dmg)
        guard let newApp = firstApp(in: mount) else {
            try? detachDMG(mount)
            throw UpdateError.noAppInDMG
        }

        try spawnSwapHelper(newApp: newApp, installURL: installURL, mount: mount, dmg: dmg)
        state = .installing
        Log.menuBar.info("Installing update \(release.version) → relaunching")
        // Let SwiftUI paint `.installing`, then quit so the helper can do the swap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// Attaches the image without a Finder window and returns its mount point,
    /// parsed from `hdiutil`'s plist output.
    private func mountDMG(_ dmg: URL) throws -> URL {
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", dmg.path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }
        return URL(fileURLWithPath: mount)
    }

    private func firstApp(in volume: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    private func detachDMG(_ mount: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mount.path, "-quiet"]
        try proc.run()
        proc.waitUntilExit()
    }

    /// Writes a one-shot script that waits for us to quit, swaps the bundle
    /// (keeping a backup to restore on failure), strips the download quarantine,
    /// unmounts, and relaunches — then spawns it detached so it outlives us.
    private func spawnSwapHelper(newApp: URL, installURL: URL, mount: URL, dmg: URL) throws {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        NEW=\(q(newApp.path))
        DEST=\(q(installURL.path))
        MOUNT=\(q(mount.path))
        DMG=\(q(dmg.path))
        PID=\(pid)
        # Wait (≤10s) for Flux to fully exit before touching its bundle.
        for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        BACKUP="${DEST}.old-$$"
        rm -rf "$BACKUP"
        if mv "$DEST" "$BACKUP" 2>/dev/null; then
          if /usr/bin/ditto "$NEW" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
            rm -rf "$BACKUP"
          else
            rm -rf "$DEST" 2>/dev/null; mv "$BACKUP" "$DEST"   # restore on failure
          fi
        fi
        /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rm -f "$DMG" 2>/dev/null || true
        /usr/bin/open "$DEST"
        rm -f "$0"
        """
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux-update-\(pid).sh")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [helper.path]
        try proc.run()   // do NOT wait — it must outlive this process
    }

    /// Fallback only: park the DMG in ~/Downloads for a manual drag-install.
    /// Never clobbers an existing file of the same name.
    private func moveToDownloads(_ dmg: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let downloads = try fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        var dest = downloads.appendingPathComponent("Flux-\(version).dmg")
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do {
            try fm.moveItem(at: dmg, to: dest)
        } catch {
            try fm.copyItem(at: dmg, to: dest)   // cross-volume safety
        }
        return dest
    }

    /// Move the URLSession download temp file to a stable, app-controlled path so
    /// it survives `runDownload` returning and can be read by the mount subprocess.
    private func stageDownload(_ temp: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent("Flux-\(version).dmg")
        if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) }
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
        case notWritable      // install location needs admin → manual fallback
        case mountFailed      // hdiutil couldn't attach the DMG → manual fallback
        case noAppInDMG       // mounted image held no .app → manual fallback
        var errorDescription: String? {
            switch self {
            case .network: return "Couldn't reach GitHub."
            case .http(let code): return "GitHub returned HTTP \(code)."
            case .notWritable: return "Flux's install location isn't writable."
            case .mountFailed: return "Couldn't mount the update image."
            case .noAppInDMG: return "The update image didn't contain Flux."
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
