import Foundation
import Combine
import OSLog
import Darwin

/// Shared logging point for the Focus subsystem — mirrors `shelfLog`'s/
/// `powerLog`'s file-scope-constant pattern rather than adding a new case to
/// `Log.swift`, since this is a self-contained M7 subsystem.
let focusLog = Logger(subsystem: "com.flux.menubar", category: "focus")

/// Best-effort Focus (Do Not Disturb / a named custom Focus mode) status,
/// read from undocumented per-user state macOS itself maintains on disk —
/// there is no public API, as of any released macOS this app targets, for
/// "what Focus is currently active." Every consumer must treat this as
/// advisory:
///
/// - `isAvailable` can go `false` at any point (see the Full Disk Access note
///   below) — this is expected, not exceptional.
/// - Any macOS release could change the on-disk shape out from under this
///   parser with no warning. The parsing below is written defensively for
///   exactly that reason: ANY failure at ANY step — file unreadable, JSON
///   malformed, a key renamed/removed/reshaped — degrades to "no Focus"
///   (`.focusChanged(name: nil, symbolName: nil)`) silently. Never a crash,
///   never a repeating log.
///
/// ## What this reads
/// Two files macOS's own Focus/Do Not Disturb machinery maintains per user:
/// `~/Library/DoNotDisturb/DB/Assertions.json` (which mode, if any, is
/// currently asserted) cross-referenced against `~/Library/DoNotDisturb/DB/
/// ModeConfigurations.json` (mode id → display name + SF Symbol name, for
/// every Focus the user has configured — Do Not Disturb, Personal, Work,
/// Sleep, or a custom one). Both are undocumented, reverse-engineered JSON
/// blobs; `Assertions.swift`/`ModeConfigurations.swift`'s exact field names
/// below are this app's best current guess at that shape and may already be
/// wrong on some macOS version — see the doc comment above on why that's a
/// silently-degrade case, not a crash.
///
/// ## Full Disk Access
/// On some macOS versions/security postures, `~/Library/DoNotDisturb` is
/// itself protected the same way `~/Library/Mail` or Safari's data is —
/// reading it can silently come back empty (not even a permission error) for
/// a process without Full Disk Access. This type never prompts for that
/// (there is no API to request it — it's a manual System Settings toggle,
/// same category as Screen Recording) and never spams the log: `isAvailable`
/// flips `false` the first time a read comes back unreadable, logged exactly
/// once for this process's whole lifetime.
@MainActor
final class FocusMonitor {
    /// `name`/`symbolName` are both `nil` exactly when no Focus is currently
    /// active — including when this feature can't read anything at all (see
    /// `isAvailable`), which is indistinguishable from "genuinely off" by
    /// design: a consumer that can't tell why must treat it identically to
    /// off, never guess.
    enum Event: Equatable {
        case focusChanged(name: String?, symbolName: String?)
    }

    let events = PassthroughSubject<Event, Never>()

    /// False once a read has come back unreadable (see the type's own doc
    /// comment on Full Disk Access) — `NotchActivityRouter` never prompts or
    /// retries eagerly off the back of this; it's exposed purely so a future
    /// caller could surface "Focus status unavailable" in Settings without
    /// re-deriving the same read-failed check itself. Starts `true`; flips
    /// `false` for the rest of this process once a read fails, since there's
    /// no signal to notice Full Disk Access being granted mid-session short
    /// of retrying on every future filesystem event anyway (which `start()`
    /// already does — see `emitCurrent()`).
    private(set) var isAvailable = true

    private var loggedUnavailable = false
    private var source: DispatchSourceFileSystemObject?
    private let directory: URL
    private var lastEvent: Event?
    /// Bot-review fix: `false` until the very first read (`start()`'s own
    /// initial `emitCurrent()` call) has established a baseline `lastEvent` —
    /// that first read never publishes through `events`, only records what it
    /// found, no matter what it found. Without this, a user who simply wasn't
    /// in any Focus at launch had that baseline read publish a synthetic
    /// `.focusChanged(name: nil, symbolName: nil)` — a real "no Focus" state,
    /// but not a CHANGE from anything, and `NotchActivityRouter` can't tell
    /// the difference between "genuinely just turned off" and "was already
    /// off before this app even started watching" — so every launch spawned
    /// a spurious "Focus off" peek. Every read AFTER this first one (a real
    /// on-disk change the `DispatchSourceFileSystemObject` below actually
    /// observed) still emits normally through `emit(_:)`. Never reset by
    /// `stop()`/`start()` cycling within the same process — once a baseline
    /// exists, a later restart seeing a different state than that baseline IS
    /// a genuine change worth reporting, not a second "first read."
    private var hasEmittedOnce = false

    /// `directory` is injectable purely for the (currently unused, but kept
    /// for parity with every other monitor's constructor-seam convention —
    /// `PowerMonitor`, `BluetoothMonitor`, etc.) possibility of pointing this
    /// at a fixture directory in a future test; `--selftest` today only
    /// exercises the pure `parse(assertionsData:configData:)` core below, no
    /// real directory watch.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    deinit {
        // The cancel handler `start()` installs closes the file descriptor
        // itself (see its own doc comment on why it captures the descriptor
        // by value rather than reaching through `self`) — `cancel()` alone
        // is enough here; there's nothing left for `deinit` to close directly.
        source?.cancel()
    }

    private static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    /// Starts watching the DB directory for changes via a
    /// `DispatchSourceFileSystemObject` — no polling, matching every other
    /// monitor in this app's zero-idle-cost perf contract. Also performs one
    /// immediate read to establish the baseline Focus state — SILENTLY (see
    /// `hasEmittedOnce`'s doc comment): whatever's already active (or not)
    /// before this app started watching isn't a "change" worth a spurious
    /// peek at every single launch. Only a genuine change AFTER that baseline
    /// — the directory actually changing under the watch below — emits.
    /// Idempotent — a second call while already watching is a no-op.
    func start() {
        guard source == nil else { return }
        emitCurrent()

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            markUnavailable()
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        // The event handler is guaranteed to run on `DispatchQueue.main`
        // (passed explicitly above) — `MainActor.assumeIsolated` is a true
        // assertion here, not an optimistic guess, mirroring
        // `VolumeMonitor`'s identical CoreAudio-listener-block pattern (see
        // its own doc comment on this exact shape).
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.emitCurrent() }
        }
        // Captures `fd` BY VALUE, not `self` — a dispatch source's cancel
        // handler runs asynchronously, possibly after this instance has
        // already been deallocated (`deinit` just calls `cancel()` and
        // relies on this handler for the actual close); a `weak self`
        // capture here would silently leak the descriptor in exactly that
        // case, since the guard would just see `self` as `nil` and return
        // without ever closing it.
        newSource.setCancelHandler {
            close(fd)
        }
        newSource.resume()
        source = newSource
    }

    /// Idempotent — a second call (or one before `start()` was ever called)
    /// is a safe no-op.
    func stop() {
        source?.cancel()
        source = nil
    }

    private func markUnavailable() {
        isAvailable = false
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        focusLog.notice("Focus status unavailable (DoNotDisturb DB unreadable — possibly missing Full Disk Access); the Focus live activity is silently disabled for this session.")
    }

    private func emitCurrent() {
        guard let assertionsData = try? Data(contentsOf: directory.appendingPathComponent("Assertions.json")),
              let configData = try? Data(contentsOf: directory.appendingPathComponent("ModeConfigurations.json"))
        else {
            markUnavailable()
            recordOrEmit(.focusChanged(name: nil, symbolName: nil))
            return
        }
        recordOrEmit(Self.parse(assertionsData: assertionsData, configData: configData))
    }

    /// Routes every `emitCurrent()` read through the `hasEmittedOnce` baseline
    /// check (see its own doc comment) before falling through to the normal
    /// dedupe-and-publish `emit(_:)` path.
    private func recordOrEmit(_ event: Event) {
        guard hasEmittedOnce else {
            hasEmittedOnce = true
            lastEvent = event
            return
        }
        emit(event)
    }

    private func emit(_ event: Event) {
        guard event != lastEvent else { return }
        lastEvent = event
        events.send(event)
    }

    // MARK: - Pure parsing (testable over fixture JSON strings, no filesystem)

    /// Mirrors `Assertions.json`'s reverse-engineered shape: a top-level
    /// `data` array (macOS's own DND storage keeps a small history/rotation
    /// of entries; only the first that actually names an active mode
    /// matters), each holding `storeAssertionRecords`, each of those an
    /// `assertionDetails` bag that — when a Focus is actually active — names
    /// the asserted mode's identifier. Every field is optional and every
    /// container defaults to empty so a reshaped/partial file decodes into
    /// "found nothing" rather than failing to decode at all.
    private struct AssertionsFile: Decodable {
        // Every field below is a plain `Optional` (not a defaulted, non-
        // optional property) deliberately: Swift's compiler-synthesized
        // `Decodable.init(from:)` calls `decode(forKey:)` — not
        // `decodeIfPresent` — for a non-optional property regardless of
        // whether it has a default value, so a missing/reshaped key would
        // throw instead of silently falling back. Optionals are the only
        // synthesis-safe way to make a missing key decode as "found
        // nothing" rather than a thrown error.
        let data: [Entry]?
        struct Entry: Decodable {
            let storeAssertionRecords: [Record]?
        }
        struct Record: Decodable {
            let assertionDetails: Details?
        }
        struct Details: Decodable {
            let assertionDetailsModeIdentifier: String?
        }
    }

    /// Mirrors `ModeConfigurations.json`'s reverse-engineered shape: a
    /// top-level `data` array, each holding a `modeConfigurations` dictionary
    /// keyed by the same mode identifier `AssertionsFile` names, each value a
    /// `modeDescriptor` carrying the mode's user-facing title and SF Symbol
    /// name.
    private struct ModeConfigurationsFile: Decodable {
        // See `AssertionsFile`'s doc comment on why every field here is a
        // plain `Optional` rather than a defaulted non-optional property.
        let data: [Entry]?
        struct Entry: Decodable {
            let modeConfigurations: [String: ModeConfiguration]?
        }
        struct ModeConfiguration: Decodable {
            let modeDescriptor: ModeDescriptor?
        }
        struct ModeDescriptor: Decodable {
            let userTitle: String?
            let symbolImageName: String?
        }
    }

    /// The first mode identifier found actually asserted, or `nil` if none is
    /// (an empty/absent `data` array, matching "no Focus active" — the
    /// overwhelmingly common case). `nil` on any decode failure too — never
    /// distinguished from "no Focus active" by design (see the type's own
    /// doc comment).
    static func activeModeIdentifier(fromAssertionsData data: Data) -> String? {
        guard let file = try? JSONDecoder().decode(AssertionsFile.self, from: data) else { return nil }
        for entry in file.data ?? [] {
            for record in entry.storeAssertionRecords ?? [] {
                if let id = record.assertionDetails?.assertionDetailsModeIdentifier {
                    return id
                }
            }
        }
        return nil
    }

    /// The display name + SF Symbol for `identifier`, or `nil` if it isn't
    /// configured (or the file fails to decode) — a mode actively asserted
    /// but missing from this file is treated the same as no Focus at all
    /// rather than showing a wing with no name/icon to give it.
    static func modeInfo(forIdentifier identifier: String, configData: Data) -> (name: String?, symbolName: String?)? {
        guard let file = try? JSONDecoder().decode(ModeConfigurationsFile.self, from: configData) else { return nil }
        for entry in file.data ?? [] {
            if let config = entry.modeConfigurations?[identifier] {
                return (config.modeDescriptor?.userTitle, config.modeDescriptor?.symbolImageName)
            }
        }
        return nil
    }

    /// The full decode pipeline as one pure function — what `emitCurrent()`
    /// calls once both files have actually been read off disk. Directly
    /// exercisable in `--selftest` against fixture JSON strings, with no real
    /// `~/Library/DoNotDisturb` involved.
    static func parse(assertionsData: Data, configData: Data) -> Event {
        guard let activeID = activeModeIdentifier(fromAssertionsData: assertionsData),
              let info = modeInfo(forIdentifier: activeID, configData: configData)
        else {
            return .focusChanged(name: nil, symbolName: nil)
        }
        return .focusChanged(name: info.name, symbolName: info.symbolName)
    }
}
