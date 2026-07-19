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
    /// Capped at `ClipboardMonitor.fullStringCap` characters (see that
    /// constant's own doc comment) — a truncation marker is appended when
    /// it is.
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

    /// Hard cap, in characters, on `ClipboardEntry.fullString` — the
    /// code-review fix for an unbounded-memory footgun: `preview` is already
    /// bounded to 200 characters (see `singleLinePreview`), but `fullString`
    /// retains the ENTIRE captured string verbatim, and up to `historyLimit`
    /// (50) entries are held at once. Copying something extremely large —
    /// hundreds of KB or more of pasted text/log/JSON — would otherwise let a
    /// single history entry (and, worst case, all 50 of them) retain that
    /// entire payload for as long as it sits in history, degrading memory
    /// use for a feature whose whole point is glanceable history, not a
    /// large-text store. 100,000 characters is generous for anything a user
    /// would plausibly want to copy back verbatim while still bounding the
    /// worst case to a few hundred KB per entry.
    static let fullStringCap = 100_000

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

    /// Set to the pasteboard's `changeCount` immediately AFTER `copyBack(_:)`
    /// finishes writing, cleared the next time `poll()` looks at it (whether
    /// or not it actually matches). Writing to `NSPasteboard` — even from
    /// this same app — bumps `changeCount` just like any external copy
    /// would, so without this, clicking a history entry to copy it back
    /// would immediately be re-captured by the very next poll as if it were
    /// a brand-new external copy, inserting a duplicate at the top of
    /// `entries`.
    ///
    /// The code-review fix this replaced was a bare `Bool` (`skipNextCapture`)
    /// that unconditionally skipped whatever the very next poll tick saw —
    /// which is wrong if some OTHER app manages to copy something in the
    /// narrow window between `copyBack(_:)`'s write and the next 1s poll:
    /// that genuinely-external copy would silently vanish, never captured at
    /// all. Comparing by the exact `changeCount` `copyBack(_:)` itself
    /// produced fixes that: only a poll tick that sees THAT precise value is
    /// skipped; a poll tick that sees anything else (an external copy having
    /// bumped the count further in the meantime) is captured normally, same
    /// as any other change.
    ///
    /// Not reset by `start()` — compare-by-value makes that unnecessary
    /// (a stale value from a previous session can never coincidentally match
    /// a NEW pasteboard's freshly-read `changeCount`, and even if it somehow
    /// did, `changeCount` only ever increases, so a later poll can't observe
    /// an old, already-passed value again). Still reset to `nil` by `stop()`,
    /// purely for cleanliness — there's no live poll left to consume it once
    /// stopped, so leaving a stale value sitting around until the next
    /// `start()` would be tidier torn down than not.
    private var suppressedChangeCount: Int?

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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suppressedChangeCount = nil
    }

    // MARK: - Polling

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Consumed (cleared) on this very next look regardless of whether it
        // matches — see `shouldSuppressCapture`'s own doc comment.
        let suppressed = suppressedChangeCount
        suppressedChangeCount = nil
        guard !Self.shouldSuppressCapture(currentChangeCount: current, suppressedChangeCount: suppressed) else { return }

        guard !isConcealedOrTransient else { return }
        guard let entry = Self.capture(from: pasteboard) else { return }
        record(entry)
    }

    /// Pure decision core of the suppression check above — split out of
    /// `poll()`, the same way `classify(string:)` is split out of
    /// `capture(from:)`, so `--selftest` can drive this directly with plain
    /// `Int`/`Int?` values. Real `NSPasteboard` read/write round-tripping
    /// isn't reliable on every CI runner this suite has to pass on (a
    /// headless runner without a full window-server session can leave
    /// `changeCount` never actually advancing no matter what's written), so
    /// the suppression logic itself — the actual code-review fix — needs a
    /// pasteboard-free seam to be testable at all. `changeCount` only ever
    /// increases, so once `currentChangeCount` has moved past a
    /// previously-suppressed value, that value can never be seen again —
    /// there's nothing left for a stale, no-longer-relevant
    /// `suppressedChangeCount` to accidentally suppress later; that's why
    /// `poll()` clears its stored value on this very call regardless of
    /// whether this returns `true` or `false`.
    static func shouldSuppressCapture(currentChangeCount: Int, suppressedChangeCount: Int?) -> Bool {
        guard let suppressedChangeCount else { return false }
        return currentChangeCount == suppressedChangeCount
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
        ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .url, preview: singleLinePreview(string), fullString: cappedFullString(string), filePaths: nil)
    }

    private static func textEntry(string: String) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .text, preview: singleLinePreview(string), fullString: cappedFullString(string), filePaths: nil)
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

    /// `string`, truncated to `fullStringCap` characters with a trailing "…"
    /// marker when it's over that cap — see `fullStringCap`'s own doc
    /// comment for why this bound exists at all. Below the cap, `string` is
    /// returned completely untouched (no marker appended) — copy-back must
    /// stay byte-for-byte exact for the overwhelming common case of
    /// ordinary-sized copies. Not `private` — like `classify(string:)`, so
    /// `--selftest` can drive both the under-cap and over-cap cases directly
    /// against a plain `String`, with no real `NSPasteboard` round-trip
    /// involved (see `shouldSuppressCapture`'s doc comment on why that
    /// matters on this suite's CI runner).
    static func cappedFullString(_ string: String) -> String {
        guard string.count > fullStringCap else { return string }
        return String(string.prefix(fullStringCap)) + "…"
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
    /// Captures `suppressedChangeCount` immediately AFTER writing — not
    /// before, unlike the old `skipNextCapture` boolean — so the value
    /// stored is the EXACT `changeCount` this write itself produced; see
    /// that property's own doc comment for why comparing by that precise
    /// value (rather than unconditionally skipping whatever the next poll
    /// tick sees) is the fix.
    func copyBack(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        switch entry.kind {
        case .file:
            guard let paths = entry.filePaths, !paths.isEmpty else { return }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            pasteboard.clearContents()
            // `[NSURL]` (not `[NSPasteboardWriting]`) — matches
            // `ShelfTileView`'s own `writeObjects([url as NSURL])` idiom;
            // `NSURL` conforms to `NSPasteboardWriting`, and Swift permits
            // passing an array of a conforming class where an array of the
            // protocol is expected.
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .text, .url, .image, .other:
            guard let fullString = entry.fullString else { return }
            pasteboard.clearContents()
            pasteboard.setString(fullString, forType: .string)
        }
        suppressedChangeCount = pasteboard.changeCount
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
