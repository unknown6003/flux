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
        case text, url, image, file, color, other
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
    /// for a different reason: an image's payload lives in `imageData`
    /// instead, since it isn't a string.
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

    /// PNG bytes for an image entry, so it can be shown as a thumbnail and
    /// copied back.
    ///
    /// This replaces a deliberate v1 limitation: images were captured as a
    /// bare "Image (W×H)" label with no payload at all, so they appeared in
    /// the list and could not be pasted. The memory concern behind that
    /// decision is real and is handled by `ClipboardMonitor.imageDataCap`
    /// instead of by refusing to store anything.
    ///
    /// `Data` rather than `NSImage`: `Equatable` (which the history list
    /// relies on), and a bounded, inspectable size.
    var imageData: Data?

    /// A small (≤`ClipboardMonitor.thumbnailPixels`) PNG for the row's
    /// thumbnail, kept separately from `imageData`.
    ///
    /// Two reasons it isn't just derived from `imageData` on demand. The row
    /// re-renders on every hover, and decoding a multi-megabyte PNG to draw
    /// it at 18×18 each time is absurd. And the full payload can be dropped
    /// by `trimImagePayloads()` when history grows, which must not also cost
    /// the entry its thumbnail — a recognisable, un-pasteable entry is far
    /// better than an anonymous "Image (W×H)" label.
    var thumbnailData: Data?

    /// The pasteboard's own bytes, held only long enough for the off-main
    /// thumbnail pass to consume them — see
    /// `ClipboardMonitor.attachThumbnailIfNeeded`. Cleared as soon as the
    /// thumbnail lands, so it never contributes to steady-state memory.
    var rawImageBytes: Data?

    /// The parsed colour for a `.color` entry, so the row can show a real
    /// swatch. Components rather than an `NSColor` for the same
    /// `Equatable`/value-type reason.
    var colorComponents: ColorComponents?

    /// A `.url` entry's destination, when it parses as something openable.
    /// Restricted to `http`/`https`, because the affordance is labelled
    /// "Open in Browser" and `NSWorkspace.open` will happily hand `ftp:`,
    /// `smb:` or any third-party custom scheme to whatever registered for it.
    /// A copied string should not be able to launch an arbitrary handler
    /// from a one-click control that says "browser".
    var linkURL: URL? {
        guard kind == .url, let fullString else { return nil }
        guard let url = URL(string: fullString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    struct ColorComponents: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    init(id: UUID, capturedAt: Date, kind: Kind, preview: String,
         fullString: String?, filePaths: [String]?,
         imageData: Data? = nil, thumbnailData: Data? = nil,
         rawImageBytes: Data? = nil, colorComponents: ColorComponents? = nil) {
        self.thumbnailData = thumbnailData
        self.rawImageBytes = rawImageBytes
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.preview = preview
        self.fullString = fullString
        self.filePaths = filePaths
        self.imageData = imageData
        self.colorComponents = colorComponents
    }
}

/// Captures clipboard changes with two complementary paths: a fast keyboard
/// copy/cut monitor for Cmd-C/Cmd-X, plus a short `changeCount` poll for menu
/// copies, screenshots, files, and scripts. Both paths are active only while
/// `start()` is enabled.
///
/// ## Why polling at all
/// `NSPasteboard` exposes no change *notification* — a bumped `changeCount`
/// since the last time this looked is the one documented way to detect "the
/// user just copied something," and polling it is Apple's own recommended
/// approach for exactly this. Keyboard monitoring closes the polling gap where
/// two quick copies could collapse into one observed pasteboard state.
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
    private var copyShortcutMonitors: [Any] = []
    private var lifecycleGeneration = 0
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
        copyShortcutMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Lifecycle

    /// No-op if already running. Re-baselines `lastChangeCount` — see the
    /// same reasoning in `init`, which applies identically to every
    /// subsequent `start()` after a `stop()`.
    func start() {
        guard timer == nil else { return }
        lifecycleGeneration += 1
        lastChangeCount = pasteboard.changeCount
        installCopyShortcutMonitors()
        // `changeCount` only reports the LATEST change, so polling alone can
        // still miss two copies inside one poll window. The keyboard monitor
        // handles Cmd-C/Cmd-X; this remains the fallback for every other
        // pasteboard producer.
        //
        // `tolerance` is set deliberately. `changeCount` is a Mach IPC
        // round-trip to `pbs`, not the local integer read an earlier comment
        // here claimed, and an untoleranced 2.9Hz timer defeats both timer
        // coalescing and App Nap — which is a real cost for an app that
        // advertises ~0% at idle. A 0.15s tolerance lets the system batch
        // these wakeups against others without materially widening the miss
        // window.
        let poll = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll.tolerance = 0.05
        timer = poll
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lifecycleGeneration += 1
        removeCopyShortcutMonitors()
        suppressedChangeCount = nil
    }

    // MARK: - Fixture injection (dev/testing only)

    /// Directly sets `entries`, bypassing the pasteboard-polling pipeline
    /// entirely. Used by `NotchSnapshot` (`--snapshot-notch`) to render
    /// deterministic fixture history offscreen, without a real `NSPasteboard`
    /// poll. Mirrors `NowPlayingService.injectPreviewState` — never called
    /// from a live poll path; `poll()` would simply overwrite it on the next
    /// tick, but a snapshot render never calls `start()`, so that never
    /// actually happens here.
    func injectPreviewEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
    }

    // MARK: - Polling

    private func poll() {
        captureIfChanged()
    }

    /// Shared capture path used by the keyboard shortcut monitor and the
    /// change-count fallback. The keyboard path calls this shortly after the
    /// copy/cut event so the source app can finish writing its pasteboard item.
    private func captureIfChanged() {
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

    // MARK: - Keyboard-assisted capture

    private func installCopyShortcutMonitors() {
        guard copyShortcutMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let isRepeat = event.isARepeat
            Task { @MainActor in
                self?.handleCopyShortcut(keyCode: keyCode, characters: characters,
                                         modifiers: modifiers, isRepeat: isRepeat)
            }
        }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleCopyShortcut(keyCode: event.keyCode,
                                     characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags,
                                     isRepeat: event.isARepeat)
            return event
        }
        copyShortcutMonitors = [global, local].compactMap { $0 }
    }

    private func removeCopyShortcutMonitors() {
        copyShortcutMonitors.forEach { NSEvent.removeMonitor($0) }
        copyShortcutMonitors.removeAll()
    }

    private func handleCopyShortcut(keyCode: UInt16, characters: String?,
                                    modifiers: NSEvent.ModifierFlags,
                                    isRepeat: Bool) {
        guard !isRepeat,
              Self.isCopyShortcut(keyCode: keyCode, characters: characters, modifiers: modifiers) else {
            return
        }

        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            // Copy/cut handlers run after the key event reaches the source
            // app. A short delay makes the read reliable for apps that write
            // rich text or image data asynchronously.
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, self.lifecycleGeneration == generation, self.timer != nil else { return }
            self.captureIfChanged()
        }
    }

    /// Pure shortcut recognition, kept separate so the event-monitor policy
    /// can be tested without creating AppKit events.
    static func isCopyShortcut(keyCode: UInt16, characters: String?,
                               modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return false
        }
        let key = characters?.lowercased()
        return key == "c" || key == "x" || keyCode == 8 || keyCode == 7
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
        trimImagePayloads()
        attachThumbnailIfNeeded(for: entry)
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
            return imageEntry(from: pasteboard, image: image)
        }
        if let string = plainText(from: pasteboard), !string.isEmpty {
            switch classify(string: string) {
            case .url: return urlEntry(string: string)
            case .color: return colorEntry(string: string)
            default: return textEntry(string: string)
            }
        }
        return otherEntry()
    }

    /// Plain text from whatever flavour the source app actually wrote.
    ///
    /// `string(forType: .string)` alone misses a real class of copies: apps
    /// that write only rich text (RTF, or HTML from a browser) leave no
    /// `public.utf8-plain-text` flavour, so capture fell through to a
    /// contentless `.other` entry — one of the "it doesn't detect everything
    /// I copy" cases. Falls back through the rich flavours and flattens them.
    /// RTF and RTFD only — **never HTML**, and that exclusion is a hard
    /// security boundary, not a scope cut.
    ///
    /// `NSAttributedString(data:options:[.documentType: .html])` is the
    /// WebKit-backed importer: it resolves and FETCHES subresources the HTML
    /// references — remote images, stylesheets — synchronously, on the main
    /// thread. Copying a page fragment containing a tracking pixel would make
    /// Flux issue an outbound request to whoever wrote it, and hang the UI
    /// until it returned. For an app whose headline invariant is that it
    /// needs no permissions and phones nowhere (see the README's Privacy
    /// section), that is disqualifying, and there is no public option to
    /// disable remote loading on that importer.
    ///
    /// The RTF importers are plain parsers with no such behaviour. An
    /// HTML-only copy therefore still falls through to `.other` — a narrower
    /// miss than the one this method was added to fix, and the correct
    /// trade.
    static func plainText(from pasteboard: NSPasteboard) -> String? {
        if let plain = pasteboard.string(forType: .string), !plain.isEmpty { return plain }
        // `.documentType` is pinned per flavour, and that is the other half
        // of the HTML exclusion. With the option omitted, the initializer
        // best-effort SNIFFS the format — so data read from the RTF flavour
        // could still be routed to the WebKit HTML importer, and the remote
        // fetch this method exists to avoid would happen anyway. Naming the
        // type removes the sniffing entirely.
        let flavours: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] =
            [(.rtf, .rtf), (.rtfd, .rtfd)]
        for (pasteboardType, documentType) in flavours {
            guard let data = pasteboard.data(forType: pasteboardType),
                  let attributed = try? NSAttributedString(
                    data: data, options: [.documentType: documentType],
                    documentAttributes: nil) else { continue }
            // Trim only to DECIDE emptiness — return the string verbatim.
            // Leading indentation and trailing newlines are often the point
            // of a copied snippet, and pasting back something subtly
            // different from what was copied is its own bug.
            let text = attributed.string
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
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
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if parseHexColor(trimmed) != nil { return .color }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return .url
        }
        return .text
    }

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`.
    ///
    /// The leading `#` is REQUIRED, deliberately. Plenty of ordinary words
    /// are valid hex — "decade", "acceded", "beefed" — and silently turning a
    /// copied word into a colour swatch is worse than missing the odd bare
    /// hex string. Pure and `static` so `--selftest` covers it without a
    /// pasteboard.
    static func parseHexColor(_ string: String) -> ClipboardEntry.ColorComponents? {
        guard string.hasPrefix("#") else { return nil }
        let body = String(string.dropFirst())
        guard !body.isEmpty, body.allSatisfy({ $0.isHexDigit }) else { return nil }

        let chars = Array(body)
        let pairs: [String]
        switch chars.count {
        case 3, 4:
            // Shorthand: each digit doubles (#abc -> #aabbcc).
            pairs = chars.map { String(repeating: String($0), count: 2) }
        case 6, 8:
            pairs = stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<$0 + 2]) }
        default:
            return nil
        }

        let values = pairs.compactMap { UInt8($0, radix: 16).map { Double($0) / 255 } }
        guard values.count == pairs.count else { return nil }
        return ClipboardEntry.ColorComponents(
            red: values[0], green: values[1], blue: values[2],
            alpha: values.count == 4 ? values[3] : 1)
    }

    private static func colorEntry(string: String) -> ClipboardEntry {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .color,
                              preview: trimmed.uppercased(),
                              fullString: cappedFullString(string), filePaths: nil,
                              colorComponents: parseHexColor(trimmed))
    }

    private static func fileEntry(urls: [URL]) -> ClipboardEntry {
        let basenames = urls.map(\.lastPathComponent).joined(separator: ", ")
        let paths = urls.map(\.path)
        return ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .file, preview: basenames, fullString: nil, filePaths: paths)
    }

    /// Longest edge of the stored thumbnail, in pixels. Generous enough for
    /// a retina 18pt row glyph with room to spare.
    static let thumbnailPixels: CGFloat = 64

    /// Total image bytes `entries` may retain across the WHOLE history, not
    /// per entry.
    ///
    /// A per-entry cap alone doesn't bound anything: 50 entries × an 8MB cap
    /// is 400MB, which is precisely the concern the original
    /// "no image payload at all" decision was avoiding. `trimImagePayloads()`
    /// drops the oldest full payloads past this budget while keeping their
    /// thumbnails, so old images stay recognisable and merely stop being
    /// pasteable.
    static let totalImageBudget = 48 * 1024 * 1024

    /// Images larger than this are kept as a label without their bytes.
    /// History holds up to `historyLimit` entries entirely in memory (never
    /// on disk — see the type's own doc comment), so a run of full-resolution
    /// retina screenshots is a real footprint. This is the budget the old
    /// "no image payload at all" decision was avoiding; setting it
    /// explicitly is better than refusing the feature.
    static let imageDataCap = 8 * 1024 * 1024

    /// Builds an image entry from the pasteboard's OWN bytes, deciding on
    /// size before doing any decoding work.
    ///
    /// The obvious shape — decode to `NSImage`, re-encode to PNG, then check
    /// the result against a cap — is what a first pass did, and it is
    /// backwards in an expensive way. A 16" full-screen screenshot is ~31MB
    /// of TIFF plus a same-sized bitmap rep plus a 7.7-megapixel PNG encode,
    /// all synchronously on the main actor inside the poll timer, and then
    /// discarded for exceeding the cap — hanging the app on every ⌃⇧⌘4 and
    /// leaving the commonest image copy of all with no payload, which is the
    /// exact "clicking it does nothing" bug the payload was added to fix.
    ///
    /// Checking the raw pasteboard bytes first means an oversized image costs
    /// one `count`. The thumbnail is still produced either way, so even an
    /// image too large to paste back is recognisable in the list.
    private static func imageEntry(from pasteboard: NSPasteboard, image: NSImage) -> ClipboardEntry {
        let size = image.size
        let preview = "Image (\(Int(size.width))×\(Int(size.height)))"
        let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let withinCap = (raw?.count ?? .max) <= imageDataCap
        // No thumbnail yet — see `attachThumbnail(to:from:)`. Building it
        // here would mean decoding a full-resolution screenshot on the main
        // actor, inside the poll timer.
        return ClipboardEntry(id: UUID(), capturedAt: Date(), kind: .image, preview: preview,
                              fullString: nil, filePaths: nil,
                              imageData: withinCap ? raw : nil,
                              rawImageBytes: raw)
    }

    /// A small PNG for the row glyph, from raw image bytes.
    ///
    /// `nonisolated` and pure so it can run off the main actor — decoding a
    /// full-resolution screenshot is hundreds of milliseconds, and doing it
    /// inline in `poll()` froze the whole app on every ⌃⇧⌘4.
    nonisolated static func thumbnailData(fromRaw raw: Data) -> Data? {
        guard let image = NSImage(data: raw) else { return nil }
        return thumbnailData(from: image)
    }

    /// Drawn into a `thumbnailPixels`-bounded bitmap rather than scaling the
    /// original on every render.
    nonisolated private static func thumbnailData(from image: NSImage) -> Data? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, thumbnailPixels / max(source.width, source.height))
        let target = NSSize(width: max(1, (source.width * scale).rounded()),
                            height: max(1, (source.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
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
    /// Builds an image entry's thumbnail off the main actor, then folds it
    /// back in.
    ///
    /// Decoding happens on a detached task because the source can be a
    /// multi-megapixel screenshot, and `record` runs on the main actor inside
    /// the poll timer. The entry is inserted immediately without a thumbnail
    /// and gains one a moment later — the row simply shows its SF Symbol
    /// until then, which is what it did for every image before this feature
    /// existed.
    ///
    /// Deliberately built from the RAW bytes rather than `imageData`, so an
    /// image too large to paste back still gets a thumbnail. An unrecognisable
    /// entry is worse than an unpasteable one.
    private func attachThumbnailIfNeeded(for entry: ClipboardEntry) {
        guard entry.kind == .image, let raw = entry.rawImageBytes else { return }
        let id = entry.id
        Task.detached(priority: .utility) {
            guard let thumbnail = Self.thumbnailData(fromRaw: raw) else { return }
            await MainActor.run { [weak self] in
                guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[index].thumbnailData = thumbnail
                // The raw copy has done its job; it would otherwise double
                // this entry's footprint for the rest of its life.
                self.entries[index].rawImageBytes = nil
            }
        }
    }

    /// Drops the oldest full image payloads once the history's total image
    /// bytes exceed `totalImageBudget`, keeping their thumbnails.
    ///
    /// The per-entry `imageDataCap` bounds one entry; only this bounds the
    /// set. Without it, 50 entries at the cap is 400MB retained in memory for
    /// a glanceable history — the exact cost the original no-image-payload
    /// decision was avoiding.
    private func trimImagePayloads() {
        var used = 0
        var overBudget = false
        for index in entries.indices where entries[index].imageData != nil {
            let size = entries[index].imageData?.count ?? 0
            // Once the budget is gone it stays gone for the rest of the pass.
            // Merely skipping an oversized entry without latching this let a
            // SMALLER, strictly OLDER entry slip into the untouched remainder
            // — so a newer image could lose its payload while an older one
            // kept it. The total stayed within budget either way, but
            // "newest wins" is the property that makes the eviction
            // predictable.
            if overBudget || used + size > Self.totalImageBudget {
                overBudget = true
                entries[index].imageData = nil   // thumbnail deliberately kept
            } else {
                used += size
            }
        }
    }

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
        case .image:
            // Copyable now — an image entry used to carry no payload, so
            // clicking one did nothing at all.
            guard let data = entry.imageData, let image = NSImage(data: data) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        case .text, .url, .color, .other:
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
