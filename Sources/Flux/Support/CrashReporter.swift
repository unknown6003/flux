import Foundation
import AppKit
import Combine
import OSLog

/// Shared logging point for crash bookkeeping — mirrors `shelfLog`'s/
/// `cameraLog`'s file-scope-constant pattern rather than adding a case to
/// `Log.swift`, since this is a self-contained subsystem.
let crashLog = Logger(subsystem: "com.flux.menubar", category: "crash")

/// Detects that the previous run of Flux ended abnormally, and remembers
/// enough about what it was doing to make the next bug report actionable.
///
/// ## Why this exists
/// Every part of the notch suite that can plausibly crash — the capture
/// session, the panel's own AppKit/SwiftUI bridge — is only reachable on real
/// notched hardware with a real camera. Development happens on a Linux box
/// where none of it can be driven, so a crash report from the user is the
/// *only* signal available, and "it crashed again, something to do with the
/// camera" isn't one that can be acted on. This turns that into "Flux quit
/// unexpectedly while the Mirror widget was open and the camera session was
/// running", plus the OS's own exception signature when it can be read.
///
/// ## Why not just read `~/Library/Logs/DiagnosticReports`?
/// It does, but only as a bonus and only when the user explicitly asks for
/// the report (`diagnosticsText()`), never at launch. Two reasons: that
/// directory isn't guaranteed readable, and this app has a hard invariant
/// that no potentially-TCC-touching API runs before an explicit user action.
/// The primary mechanism below touches nothing outside Flux's own
/// Application Support container, so it works unconditionally.
///
/// ## How the detection works
/// A session file is written at launch with `endedCleanly: false` and
/// rewritten as breadcrumbs change. `applicationWillTerminate` flips it to
/// `true`. A crash never gets to run that, so finding `false` at the *next*
/// launch means the last session died. This deliberately can't distinguish a
/// crash from a force-quit or a logout that killed the app — hence the
/// wording "quit unexpectedly" rather than "crashed", and hence the OS
/// crash-report lookup, which is what actually disambiguates them.
///
/// ## Privacy
/// `Breadcrumb` is a closed set of enum-ish strings describing Flux's own UI
/// state. It carries no clipboard contents, no file names, no event titles,
/// no window titles — nothing derived from user data at all. That's a
/// deliberate constraint, not an accident of the current fields: this file is
/// written to disk and shown in a copyable report, so anything added to it
/// must be Flux's own state, never the user's.
@MainActor
final class CrashReporter: ObservableObject {

    /// A tiny, privacy-safe description of what Flux was doing. Every field
    /// is Flux's own UI state — see the type's doc comment on why that's a
    /// hard constraint.
    struct Breadcrumb: Codable, Equatable {
        /// `NotchState` rendered as a stable string ("collapsed",
        /// "activity", "expanded(mirror)"). Not the enum itself: `NotchState`
        /// carries a `UUID` and would tie this file's on-disk format to a
        /// type that changes for UI reasons.
        var notchState: String = "collapsed"
        /// Whether `CameraService`'s capture session was running. Called out
        /// separately from `notchState` because the session outliving its
        /// widget is exactly the class of bug this is here to catch.
        var cameraRunning: Bool = false
        /// The kind of the live activity showing, if any.
        var activityKind: String?
        /// Whether the Settings window was open.
        var settingsOpen: Bool = false

        init() {}

        /// Every field optional-with-default, for the same forward-
        /// compatibility reason spelled out on `Session`.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notchState = try container.decodeIfPresent(String.self, forKey: .notchState) ?? "collapsed"
            cameraRunning = try container.decodeIfPresent(Bool.self, forKey: .cameraRunning) ?? false
            activityKind = try container.decodeIfPresent(String.self, forKey: .activityKind)
            settingsOpen = try container.decodeIfPresent(Bool.self, forKey: .settingsOpen) ?? false
        }
    }

    /// One session's worth of bookkeeping, as persisted.
    ///
    /// ## Decoding is hand-written, and that is load-bearing
    /// Swift's synthesized `init(from:)` does NOT fall back to a stored
    /// property's default value — `= "collapsed"` and friends do nothing for
    /// decoding. So the moment anyone adds a non-optional field to `Session`
    /// or `Breadcrumb`, a synthesized decoder would throw on every file
    /// written by the previous build, `readSession()`'s `try?` would swallow
    /// it, and the first launch after that upgrade would report "no crash"
    /// for a run that really did crash — precisely the case this whole file
    /// exists to catch, failing silently and in the wrong direction.
    ///
    /// Decoding every field with `decodeIfPresent(...) ?? default` makes a
    /// added-field upgrade a non-event. Anything added later must follow the
    /// same pattern.
    struct Session: Codable, Equatable {
        var version: String
        var build: String
        var startedAt: Date
        var updatedAt: Date
        var endedCleanly: Bool
        var breadcrumb: Breadcrumb

        init(version: String, build: String, startedAt: Date, updatedAt: Date,
             endedCleanly: Bool, breadcrumb: Breadcrumb) {
            self.version = version
            self.build = build
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.endedCleanly = endedCleanly
            self.breadcrumb = breadcrumb
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
            build = try container.decodeIfPresent(String.self, forKey: .build) ?? "unknown"
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
            // The one field with a deliberately PESSIMISTIC default. A file
            // that exists but can't be read as clean is, as far as this can
            // tell, a session that never got to mark itself clean.
            endedCleanly = try container.decodeIfPresent(Bool.self, forKey: .endedCleanly) ?? false
            breadcrumb = try container.decodeIfPresent(Breadcrumb.self, forKey: .breadcrumb) ?? Breadcrumb()
        }
    }

    /// The previous session, when it ended abnormally. `nil` on a first-ever
    /// launch, after a clean previous run, or once the user dismisses it.
    /// Settings renders a card from this.
    @Published private(set) var lastUncleanSession: Session?

    /// Whether `beginSession()` has run. Guards the double-call that a
    /// `--selftest`/`--snapshot` invocation could otherwise produce.
    private var started = false
    private var current: Session?
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let base = fileManagerBase()
        return base.appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    /// Matches `ShelfStore.defaultDirectory()`'s reasoning: practically never
    /// nil on macOS, but fall back to a still-per-user location rather than
    /// force-unwrapping.
    private static func fileManagerBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Session lifecycle

    /// Reads the previous session (publishing it as `lastUncleanSession` when
    /// it never ended cleanly), then opens a fresh one. Call once, early in
    /// `applicationDidFinishLaunching`.
    func beginSession() {
        guard !started else { return }
        started = true

        if let previous = readSession(), !previous.endedCleanly {
            lastUncleanSession = previous
            crashLog.error("""
                Previous Flux session (v\(previous.version, privacy: .public) build \
                \(previous.build, privacy: .public)) ended without a clean shutdown — \
                notch was \(previous.breadcrumb.notchState, privacy: .public), \
                camera running: \(previous.breadcrumb.cameraRunning, privacy: .public)
                """)
        }

        let now = Date()
        current = Session(version: AppInfo.version, build: AppInfo.build,
                          startedAt: now, updatedAt: now,
                          endedCleanly: false, breadcrumb: Breadcrumb())
        writeNow()
    }

    /// Marks this session clean. Call from `applicationWillTerminate` — a
    /// crash never reaches it, which is precisely the signal.
    func endSession() {
        guard var session = current else { return }
        session.endedCleanly = true
        session.updatedAt = Date()
        current = session
        writeNow()
    }

    /// Mutates the live breadcrumb and persists it IMMEDIATELY.
    ///
    /// Deliberately not coalesced onto a later runloop turn, which is the
    /// obvious optimisation and the wrong one: the single most valuable
    /// breadcrumb is the one describing the state Flux was in when it died,
    /// and a crash arriving between the state change and a deferred write
    /// would lose exactly that. The write is a couple of hundred bytes, and
    /// these are discrete UI events (a notch transition, the camera starting)
    /// — not a per-frame path — so paying for it synchronously is cheap
    /// insurance. The no-op guard below means an unchanged breadcrumb costs
    /// nothing at all.
    func update(_ mutate: (inout Breadcrumb) -> Void) {
        guard var session = current else { return }
        var breadcrumb = session.breadcrumb
        mutate(&breadcrumb)
        guard breadcrumb != session.breadcrumb else { return }
        session.breadcrumb = breadcrumb
        session.updatedAt = Date()
        current = session
        writeNow()
    }

    /// The user has seen the notice. Clears the published banner only — the
    /// on-disk record needs no clearing, because `beginSession()` already
    /// overwrote the file with THIS session before publishing it, so there is
    /// nothing left that could resurface at the next launch. (Said explicitly
    /// because the previous wording claimed this cleared the file too, which
    /// would have licensed moving that write later and quietly turning a
    /// dismissed notice into a recurring one.)
    func dismissLastUncleanSession() {
        lastUncleanSession = nil
    }

    // MARK: - Report

    /// A copyable plain-text report: Flux's own version/state breadcrumb plus,
    /// best effort, the OS's crash-report signature for the matching crash.
    ///
    /// The `DiagnosticReports` read happens HERE and nowhere else — i.e. only
    /// in response to the user pressing "Copy Report" — so nothing this app
    /// does at launch or in the background ever touches a directory outside
    /// its own container. A failure is silent by design: the breadcrumb half
    /// is still worth having on its own.
    func diagnosticsText() -> String {
        var lines: [String] = []
        lines.append("Flux \(AppInfo.version) (build \(AppInfo.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        if let session = lastUncleanSession {
            lines.append("")
            lines.append("Previous session ended unexpectedly")
            lines.append("  ran:            \(Self.format(session.startedAt)) → \(Self.format(session.updatedAt))")
            lines.append("  version:        \(session.version) (build \(session.build))")
            lines.append("  notch state:    \(session.breadcrumb.notchState)")
            lines.append("  camera running: \(session.breadcrumb.cameraRunning)")
            lines.append("  live activity:  \(session.breadcrumb.activityKind ?? "none")")
            lines.append("  settings open:  \(session.breadcrumb.settingsOpen)")
        }

        // Matched against the unclean session's own time window, not merely
        // "newest recent" — see `latestCrashReportSummary`.
        if let report = Self.latestCrashReportSummary(
            session: lastUncleanSession,
            // This launch's own start is the upper bound: whatever killed the
            // previous session necessarily happened before Flux came back.
            nextSessionStart: current?.startedAt ?? Date()) {
            lines.append("")
            lines.append("System crash report")
            lines.append(report)
        } else {
            lines.append("")
            lines.append("System crash report: none found (or not readable) in ~/Library/Logs/DiagnosticReports")
        }
        return lines.joined(separator: "\n")
    }

    /// Locale/calendar/timezone pinned explicitly. A bare `DateFormatter`
    /// with a fixed `dateFormat` still renders through the *user's* locale
    /// and calendar, so the same report could come back in a non-Gregorian
    /// calendar or with localised numerals — unreadable to whoever it's sent
    /// to, and not comparable against anything. `en_US_POSIX` is the standard
    /// answer for a machine-readable timestamp.
    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        return formatter.string(from: date)
    }

    /// Replaces the user's home directory with `~` anywhere it appears.
    ///
    /// Crash-report lines are copied verbatim into something the user then
    /// pastes into a bug report, and an `.ips` termination/exception line can
    /// carry absolute paths — which embed the account's short name. That's
    /// gratuitous for diagnosing a crash, and this file's whole premise (see
    /// the type doc comment's privacy note) is that nothing user-identifying
    /// leaves the machine by accident.
    static func redactingHome(_ line: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, home != "/" else { return line }
        return line.replacingOccurrences(of: home, with: "~")
    }

    /// Slack on the upper bound, for the gap between the previous process
    /// dying and this one starting.
    static let reportMatchGrace: TimeInterval = 120

    /// Whether a crash report written at `reportDate` belongs to `session`,
    /// given that the NEXT session started at `nextSessionStart`.
    ///
    /// The window is `[session.startedAt, nextSessionStart + grace]`.
    ///
    /// Bounding by the next launch rather than by `session.updatedAt` is
    /// load-bearing. `updatedAt` only advances when a breadcrumb actually
    /// changes — there is no heartbeat — so a Flux left collapsed and idle
    /// has `updatedAt == startedAt`, i.e. launch time. Bounding on it (as a
    /// first pass at this did) meant a crash three hours into an idle run
    /// sat hours outside the window and was discarded, silently degrading
    /// every report to breadcrumb-only. For a menu-bar app that idles most
    /// of its life, that's the common case, not the corner.
    ///
    /// The lower bound still matters, and is the whole reason this exists:
    /// without it, crashing on Monday and force-quitting on Friday stapled
    /// Monday's exception signature onto Friday's unclean exit.
    ///
    /// Pure, so `--selftest` can cover it without a crash to find.
    static func reportMatches(session: Session, reportDate: Date, nextSessionStart: Date) -> Bool {
        reportDate >= session.startedAt
            && reportDate <= nextSessionStart.addingTimeInterval(reportMatchGrace)
    }

    /// The crash report belonging to `session`, if one exists and is
    /// readable. Deliberately extracts only a handful of *signature* fields
    /// rather than pasting the whole `.ips` — a full report is hundreds of
    /// lines of address soup, and includes loaded-library paths that leak
    /// more about the user's machine than a bug report needs.
    ///
    /// With no session to match against there is nothing to attribute a
    /// report to, so this returns nil rather than guessing.
    static func latestCrashReportSummary(session: Session?, nextSessionStart: Date,
                                         directory: URL? = nil) -> String? {
        guard let session else { return nil }

        let reportsDir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        let candidates = entries
            .filter { isFluxCrashReport($0.lastPathComponent) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return (url, date)
            }
            .filter { reportMatches(session: session, reportDate: $0.1, nextSessionStart: nextSessionStart) }
            // Newest *within the matching window*: if a session somehow
            // produced more than one report, the last one is the fatal one.
            .sorted { $0.1 > $1.1 }

        guard let newest = candidates.first,
              let contents = try? String(contentsOf: newest.0, encoding: .utf8)
        else { return nil }

        return summarize(reportContents: contents, fileName: newest.0.lastPathComponent)
    }

    /// Whether a `DiagnosticReports` filename is one of Flux's own crashes.
    /// macOS names them `Flux-2026-07-27-134500.ips` (and historically
    /// `.crash`); the `Flux-` prefix check is what keeps this from reading
    /// every other app's reports. Pure, so `--selftest` can cover it without
    /// a crash to find.
    static func isFluxCrashReport(_ fileName: String) -> Bool {
        guard fileName.hasPrefix("\(AppInfo.name)-") else { return false }
        return fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash")
    }

    /// Pulls the signature lines out of a crash report's text. Pure and
    /// selftest-covered against both the modern JSON-ish `.ips` header and
    /// the older plain-text `.crash` layout, since which one a given macOS
    /// writes isn't something this can control.
    static func summarize(reportContents: String, fileName: String) -> String {
        var picked: [String] = ["  file: \(fileName)"]
        let interesting = ["exceptionType", "Exception Type", "termination",
                           "Termination Reason", "faultingThread", "Crashed Thread"]
        for line in reportContents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard interesting.contains(where: { trimmed.contains($0) }) else { continue }
            // Long JSON lines from an `.ips` header would otherwise dump the
            // entire single-line payload into the report.
            picked.append("  " + redactingHome(String(trimmed.prefix(300))))
            // `>=`, checked after the append: the file-name line occupies
            // slot 0, so this keeps the filename plus 8 signature lines.
            if picked.count >= 9 { break }
        }
        return picked.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func writeNow() {
        guard let current else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(current)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Never fatal: this is diagnostics. Losing it costs a nicer bug
            // report, not correctness.
            crashLog.error("Could not write the session file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A missing file is the normal first-launch case and stays quiet. A file
    /// that exists but won't decode is NOT normal — it means crash detection
    /// is silently disabled for this launch, so it gets logged rather than
    /// swallowed by a bare `try?`.
    private func readSession() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            crashLog.error("""
                Session file exists but could not be decoded — crash detection \
                is inactive for this launch: \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }
}
