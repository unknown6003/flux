import AppKit
import Combine
import OSLog

/// Shared logging point for the clipboard subsystem (M6's Clipboard widget)
/// — mirrors `cameraLog`'s/`calendarLog`'s file-scope-constant pattern rather
/// than adding a new case to `Log.swift`, since this is a self-contained M6
/// subsystem the notch suite owns.
let clipboardLog = Logger(subsystem: "com.flux.menubar", category: "clipboard")

/// One pasteboard change captured into clipboard history.
struct ClipboardEntry: Identifiable, Equatable {
    /// What kind of content this entry holds — drives `ClipboardWidget`'s
    /// per-row SF Symbol.
    enum Kind: String, Equatable {
        case text, url, image, file, other
    }

    let id: UUID
    let capturedAt: Date
    let kind: Kind
    /// Single-line, ≤200-character summary shown in the row — always cheap
    /// and safe to render, unlike `fullString`, which can be considerably
    /// larger (or, for images, is deliberately absent entirely).
    let preview: String
    /// What `copyBack(_:)` writes back to the pasteboard for `.text`/`.url`/
    /// `.other` entries: the full captured string, verbatim. Always `nil`
    /// for `.file` entries — those round-trip through `filePaths` instead
    /// (a newline-joined string would corrupt any path that itself contains
    /// a newline, however rare) — and for `.image` entries, where it's `nil`
    /// for a different reason: retaining decoded image bytes for
    /// potentially 50 history entries at once (`historyLimit`) is a real
    /// RAM cost for a feature whose whole point is glanceable history, not
    /// an image library — so v1 deliberately shows an image entry for
    /// context only (`preview` describes its dimensions) with no copy-back
    /// and no retained pixel data at all. A future milestone that wants
    /// image copy-back should budget the memory cost explicitly rather
    /// than this type accumulating it as a side effect of history.
    let fullString: String?
    /// Every captured file path, one element per file — `.file` entries
    /// only, `nil` for every other kind. Kept as a real `[String]` (rather
    /// than joined into `fullString`) so `copyBack(_:)` can write each path
    /// back as its own file-URL pasteboard item without ever having to
    /// split a joined string apart again, which would silently corrupt any
    /// path containing a newline.
    let filePaths: [String]?
}

/// Polls `NSPasteboard.general.changeCount` on a 1-second timer — the ONLY
/// timer this type ever runs, and only for as long as `start()` has been
/// called. This is the notch suite's zero-idle-timer perf contract applied
/// here exactly the way `ShelfStore`/`CalendarService` apply it to their own
/// on-access/notification-driven work: no repeating work at all while the
/// feature is switched off.
///
/// ## Why polling at all
/// `NSPasteboard` exposes no change *notification* — a bumped `changeCount`
/// since the last time this looked is the one documented way to detect "the
/// user just copied something," and polling it is Apple's own recommended
/// approach for exactly this. A 1-second interval captures a copy
/// effectively instantly from the user's perspective without making this app
/// meaningfully busier than any other once-a-second idle tick.
///
/// ## Lifecycle: driven by the SETTINGS toggle, not widget visibility
/// Unlike every other notch-suite service, this one's `start()`/`stop()` are
/// NOT called from `ClipboardWidget`'s `willPresent()`/`didDismiss()` — the
/// entire point of a clipboard *history* is that it keeps accumulating while
/// the widget is closed, so there's something to scroll back through the
/// next time it's opened. The wiring agent is expected to call
/// `start()`/`stop()` from a Combine sink on the relevant `SettingsStore`
/// toggle instead — see `ClipboardWidget`'s own doc comment.
@MainActor
final class ClipboardMonitor: ObservableObject {
    /// Newest-first. Capped at `historyLimit` — see `record(_:)`.
    @Published private(set) var entries: [ClipboardEntry] = []

    /// Hard cap on in-memory history — and there is no disk persistence at
    /// all, by design: clipboard contents routinely include passwords,
    /// one-time codes, and other sensitive text a user only meant to paste
    /// once, and writing any of that to disk (even locally) is a much bigger
    /// promise than a v1 clipboard-history feature should make. 50 is
    /// generous for "what did I copy a few things ago" without letting the
    /// list — and the strings it holds — grow unbounded across a long
    /// session.
    static let historyLimit = 50

    /// Password managers (1Password, Bitwarden, and most others) mark a
    /// copied secret with one or both of these pasteboard types, per the
    /// long-standing (if informal) `nspasteboard.org` convention that many
    /// clipboard-history/manager apps on macOS already honor. Any pasteboard
    /// item carrying either is skipped entirely — never captured, never
    /// logged with content, just silently passed over — rather than this
    /// feature becoming a second place a leaked password ends up sitting in
    /// plaintext history.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    /// Set right before `copyBack(_:)` writes to the pasteboard, cleared
    /// right after the next poll tick consumes it. Writing to
    /// `NSPasteboard` — even from this same app — bumps `changeCount` just
    /// like any external copy would, so without this, clicking a history
    /// entry to copy it back would immediately be re-captured by the very
    /// next poll as if it were a brand-new external copy, inserting a
    /// duplicate at the top of `entries`. Also reset (to `false`) by both
    /// `start()` and `stop()`, so a flag set right before a `stop()` (e.g.
    /// the settings toggle flips off between `copyBack(_:)` and the next
    /// tick) can never survive into a later `start()` and silently swallow
    /// the first real external capture after the feature is re-enabled.
    private var skipNextCapture = false

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // Baseline to whatever's on the pasteboard right now, not `0` —
        // otherwise the very first `start()` in a session would treat
        // content copied before Flux launched (or while this monitor was
        // stopped) as a fresh change and capture it as if it just happened.
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// No-op if already running. Re-baselines `lastChangeCount` — see the
    /// same reasoning in `init`, which applies identically to every
    /// subsequent `start()` after a `stop()`.
    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        skipNextCapture = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        skipNextCapture = false
    }

    // MARK: - Polling

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard !skipNextCapture else {
            skipNextCapture = false
            return
        }
        guard !isConcealedOrTransient else { return }
        guard let entry = Self.capture(from: pasteboard) else { return }
        record(entry)
    }

    private var isConcealedOrTransient: Bool {
        guard let items = pasteboard.pasteboardItems else { return false }
        return items.contains { item in
            item.types.contains(Self.concealedType) || item.types.contains(Self.transientType)
        }
    }

    private func record(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.historyLimit {
            entries.removeLast(entries.count - Self.historyLimit)
        }
        clipboardLog.debug("Clipboard: captured a \(entry.kind.rawValue, privacy: .public) entry")
    }

    // MARK: - Capture (pure-ish — reads the pasteboard, builds no side effects)

    /// Builds an entry from whatever's currently on `pasteboard`, in
    /// priority order: file URLs, then image data, then a URL-shaped string,
    /// then plain text, then a generic `.other` fallback for anything with
    /// content but none of those recognizable forms. `nil` only when the
    /// pasteboard has no items at all (e.g. some other app called
    /// `clearContents()` without writing anything back) — nothing worth
    /// recording as a "copy" in that case.
    private static func capture(from pasteboard: NSPasteboard) -> ClipboardEntry? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return fileEntry(urls: urls)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return imageEntry(image: image)
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            switch classify(string: string) {
            case .url: return urlEntry(string: string)
            default: return textEntry(string: string)
            }
        }
        return otherEntry()
    }

    /// Pure text-vs-URL classification for a captured string — split out of
    /// `capture(from:)` so `--selftest` can drive every case (a bare word, a
    /// full URL, a scheme with no host, ...) directly against a plain
    /// `String`, with no `NSPasteboard` involved at all. Only ever returns
    /// `.url` or `.text`: everything else `ClipboardEntry.Kind` can be
    /// (`.file`, `.image`, `.other`) is decided earlier in `capture(from:)`
    /// by what's actually on the pasteboard, not by inspecting string
    /// content.
    static func classify(string: String) -> ClipboardEntry.Kind {
        if let url = URL(string: string), url.scheme != nil, url.host != nil {
            return .url
        }
        return .text
    }

    private static func fileEntry(urls: [URL]) -> ClipboardEntry {
        let basenames = urls.map(\.lastPathComponent).joined(separator: ", ")
        let paths = urls.map(\.path)
        return ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .file, preview: basenames, fullString: nil, filePaths: paths)
    }

    private static func imageEntry(image: NSImage) -> ClipboardEntry {
        let size = image.size
        let preview = "Image (\(Int(size.width))×\(Int(size.height)))"
        return ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .image, preview: preview, fullString: nil, filePaths: nil)
    }

    private static func urlEntry(string: String) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .url, preview: singleLinePreview(string), fullString: string, filePaths: nil)
    }

    private static func textEntry(string: String) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .text, preview: singleLinePreview(string), fullString: string, filePaths: nil)
    }

    private static func otherEntry() -> ClipboardEntry {
        ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .other, preview: "Unsupported clipboard content", fullString: nil, filePaths: nil)
    }

    /// First 200 characters, collapsed to a single line (newlines/tabs
    /// folded to spaces) — the row's preview text only; `fullString` always
    /// carries the untruncated original.
    private static func singleLinePreview(_ string: String) -> String {
        let collapsed = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(collapsed.prefix(200))
    }

    // MARK: - Actions

    /// Writes `id`'s captured content back to the pasteboard: text/url/other
    /// entries as a plain string (from `fullString`), file entries as real
    /// file-URL pasteboard items built directly from `filePaths` — no
    /// join-then-split round trip, so a path containing a newline still
    /// copies back correctly. A no-op for image entries (nothing captured to
    /// write back) or an `id` no longer present in `entries` (e.g. removed,
    /// or the list was cleared, between the tap and this call).
    ///
    /// Sets `skipNextCapture` before writing so the poll tick this write
    /// itself triggers doesn't re-capture the entry as a duplicate — see
    /// that property's own doc comment.
    func copyBack(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        switch entry.kind {
        case .file:
            guard let paths = entry.filePaths, !paths.isEmpty else { return }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            skipNextCapture = true
            pasteboard.clearContents()
            // `[NSURL]` (not `[NSPasteboardWriting]`) — matches
            // `ShelfTileView`'s own `writeObjects([url as NSURL])` idiom;
            // `NSURL` conforms to `NSPasteboardWriting`, and Swift permits
            // passing an array of a conforming class where an array of the
            // protocol is expected.
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .text, .url, .image, .other:
            guard let fullString = entry.fullString else { return }
            skipNextCapture = true
            pasteboard.clearContents()
            pasteboard.setString(fullString, forType: .string)
        }
    }

    /// Removes one entry from history — backs `ClipboardWidget`'s per-row
    /// hover ✕. A no-op if `id` isn't (or is no longer) present.
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Empties history entirely — backs `ClipboardWidget`'s "Clear All".
    /// Does not touch the live pasteboard itself, only this monitor's
    /// in-memory history.
    func clear() {
        entries.removeAll()
    }
}
