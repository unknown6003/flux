import SwiftUI
import AppKit
import Foundation

/// Renders `NotchRootView` off-screen at a fixed size for visual review, via
/// `OffscreenRender`'s shared pipeline — for the notch panel, which (unlike
/// Settings) has no window of its own to screenshot outside a real notch Mac.
///
///   Flux --snapshot-notch <path> [dark] [collapsed|activity|expanded]
///   Flux --snapshot-notch <dir> all [dark]   (batch mode — see `captureAll`)
@MainActor
enum NotchSnapshot {
    /// A representative built-in notch footprint (matches recent MacBook Pro
    /// notch proportions). The panel's fixed bounds are derived from this via
    /// `NotchMetrics.panelBounds`, the same way `NotchWindowController.
    /// position` does; the *visible* shape is smaller still — see
    /// `NotchMetrics.expandedWidth`/`expandedHeight`.
    private static let notchSize = CGSize(width: 180, height: 32)

    static func capture(to path: String, dark: Bool, state: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        let (root, panelSize) = buildRoot(for: state)

        // Transparent (not opaque) window: the notch panel draws its own
        // shape over nothing, unlike Settings' real window chrome.
        OffscreenRender.capture(rootView: root, size: panelSize, dark: dark,
                                opaque: false, label: "snapshot-notch", to: path)
    }

    /// Batch mode behind CI's "Render notch snapshots" step: renders every
    /// notch widget's expanded state (plus a few representative empty/
    /// permission/duo variants) into fixed filenames under `dir`, in one
    /// process launch, so the whole notch suite's layout can be reviewed from
    /// one CI artifact rather than only the three states M7 shipped with.
    ///
    /// Deliberately does NOT reuse `capture(to:dark:state:)` for this: that
    /// function ends in `OffscreenRender.capture`, which always calls
    /// `exit()` once it's written its one PNG (every other snapshot flag is
    /// single-shot, so that's the right contract there) — calling it
    /// repeatedly would just exit the process after the first file.
    /// `OffscreenRender.render` — the same recipe with the `exit()` left out —
    /// is what this loops over instead, so every state renders and this
    /// function exits exactly once, itself, at the end.
    static func captureAll(to dir: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let states: [(state: String, file: String)] = [
            ("collapsed", "collapsed.png"),
            ("activity", "activity.png"),
            ("expanded", "expanded-nowPlaying.png"),
            ("expanded-shelf", "expanded-shelf.png"),
            ("empty-shelf", "empty-shelf.png"),
            ("expanded-calendar", "expanded-calendar.png"),
            ("empty-calendar", "empty-calendar.png"),
            ("expanded-timers", "expanded-timers.png"),
            ("expanded-clipboard", "expanded-clipboard.png"),
            ("expanded-mirror", "expanded-mirror.png"),
            ("expanded-duo", "expanded-duo.png"),
        ]

        var allSucceeded = true
        for (state, file) in states {
            let (root, panelSize) = buildRoot(for: state)
            let path = (dir as NSString).appendingPathComponent(file)
            // Transparent (not opaque), matching `capture(to:dark:state:)`
            // above — the notch panel draws its own shape over nothing.
            // `OffscreenRender.render` already writes its own "wrote"/failure
            // diagnostic to stderr (prefixed with `label`), so there's no
            // need to duplicate that here.
            if !OffscreenRender.render(rootView: root, size: panelSize, dark: dark, opaque: false,
                                       label: "snapshot-notch", to: path) {
                allSucceeded = false
            }
        }
        exit(allSucceeded ? 0 : 1)
    }

    /// Shared setup behind both entry points above: a fresh registry/service/
    /// view model per call (so no state leaks between `captureAll`'s
    /// iterations), seeded and transitioned to `state`, plus the fixed panel
    /// bounds (`NotchMetrics.panelBounds`) that state should render at.
    ///
    /// Every one of the six widgets is registered here (not just whichever
    /// one `state` is about to expand) — matching how `AppDelegate` wires the
    /// real app, and required for `expanded-duo` (which needs both Now
    /// Playing and Calendar registered at once).
    private static func buildRoot(for state: String) -> (AnyView, CGSize) {
        let registry = NotchWidgetRegistry()
        let activities = LiveActivityCenter()

        let nowPlayingService = NowPlayingService()
        let shelfStore = ShelfStore(directory: makeTempShelfDirectory())
        let calendarService = CalendarService()
        let permissions = PermissionCenter()
        let cameraService = CameraService()
        let timerService = TimerService()
        let clipboardMonitor = ClipboardMonitor()

        registry.register(NowPlayingWidget(service: nowPlayingService))
        registry.register(ShelfWidget(store: shelfStore))
        registry.register(CalendarWidget(service: calendarService, permissions: permissions))
        registry.register(MirrorWidget(service: cameraService, permissions: permissions))
        registry.register(TimersWidget(service: timerService))
        registry.register(ClipboardWidget(monitor: clipboardMonitor))
        registry.order = WidgetID.allCases

        let viewModel = NotchViewModel(registry: registry, activities: activities)

        switch state {
        case "activity":
            activities.post(LiveActivity(
                kind: .nowPlaying,
                leading: .artwork,
                trailing: .iconText(systemName: "waveform", text: "1:24"),
                duration: nil,
                priority: 200))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            // Seed AFTER the spin: posting/expanding can start real sources
            // (adapter unavailable on CI publishes nil), which would overwrite
            // an earlier injection during the run-loop turn.
            seedFixtureState(into: nowPlayingService)

        case "expanded":
            viewModel.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            seedFixtureState(into: nowPlayingService)

        case "expanded-shelf":
            seedShelfFixtures(into: shelfStore)
            viewModel.expand(.shelf)
            // `ShelfWidget.willPresent()` kicks off `ensureThumbnails()`
            // asynchronously (QuickLook's completion hops back to the main
            // actor) — wait for it so the render shows real thumbnails/icons
            // rather than every tile's "not ready yet" placeholder.
            waitForShelfThumbnails(shelfStore)

        case "empty-shelf":
            viewModel.expand(.shelf)

        case "expanded-calendar":
            // Expand first — `CalendarWidget.willPresent()` calls
            // `permissions.refresh(.calendar)`, a REAL (synchronous) TCC
            // query that would clobber an injected `.granted` if this ran
            // the other way around. Inject the fixture events/permission
            // AFTER, once nothing left in this state's path can overwrite
            // either.
            viewModel.expand(.calendar)
            calendarService.injectPreviewEvents(calendarFixtureEvents())
            permissions.injectPreviewStatus(.calendar, .granted)

        case "empty-calendar":
            viewModel.expand(.calendar)
            // No `injectPreviewEvents` call — `upcoming` stays at its default
            // empty array, so the agenda renders its "No upcoming events"
            // empty state instead of the permission explainer.
            permissions.injectPreviewStatus(.calendar, .granted)

        case "expanded-timers":
            // `TimerService.start(duration:label:)` is the real, already-
            // public API — no fixture seam needed. Remaining time is derived
            // from `startedAt`, so starting these immediately before render
            // (rather than injecting a frozen "remaining" value) lands
            // almost exactly on the durations below.
            timerService.start(duration: 4 * 60 + 32, label: "Break")
            timerService.start(duration: 24 * 60 + 10, label: "Focus")
            viewModel.expand(.timers)

        case "expanded-clipboard":
            clipboardMonitor.injectPreviewEntries(clipboardFixtureEntries())
            viewModel.expand(.clipboard)

        case "expanded-mirror":
            // Expand first, same ordering reasoning as "expanded-calendar" —
            // `MirrorWidget.willPresent()` both refreshes the permission
            // status AND opens a live `permissions.$statuses` subscription
            // that reacts to this injection the instant it publishes,
            // attempting `cameraService.start()`. There's no camera on CI
            // (`isAvailable == false`), so that attempt no-ops and the panel
            // renders its "No camera found" empty state — still exactly what
            // this snapshot is for: reviewing the GRANTED-but-no-hardware
            // layout, not a live feed.
            viewModel.expand(.mirror)
            permissions.injectPreviewStatus(.camera, .granted)

        case "expanded-duo":
            viewModel.duoActive = true
            viewModel.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            seedFixtureState(into: nowPlayingService)
            // The state machine only ever transitions to `.expanded(.nowPlaying)`
            // here — Duo view renders Calendar's `makeExpandedView()` directly
            // (see `NotchRootView.duoContent`) without ever calling
            // `CalendarWidget.willPresent()`, so there's no live permission
            // refresh in this path to race against; these two injections are
            // safe in either order.
            calendarService.injectPreviewEvents(calendarFixtureEvents())
            permissions.injectPreviewStatus(.calendar, .granted)

        default:
            break // "collapsed" — leave the view model at its initial .collapsed state
        }

        let root = NotchRootView(viewModel: viewModel, notchSize: notchSize, artworkProvider: { [weak nowPlayingService] in
            nowPlayingService?.artwork
        })
        let panelSize = NotchMetrics.panelBounds(for: notchSize.width)
        return (AnyView(root), panelSize)
    }

    /// Decodes the checked-in `streamFullSnapshotJSON` fixture (see
    /// `NowPlayingFixtures`) into a real `NowPlayingState` and injects it —
    /// giving the widget deterministic title/artist/artwork to render
    /// without spawning any real Now Playing source.
    private static func seedFixtureState(into service: NowPlayingService) {
        guard let data = NowPlayingFixtures.streamFullSnapshotJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadDict = object["payload"] as? [String: Any],
              JSONSerialization.isValidJSONObject(payloadDict),
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict),
              let payload = try? JSONDecoder().decode(MediaRemoteAdapterPayload.self, from: payloadData),
              var state = NowPlayingState(payload: payload)
        else { return }

        // The fixture's `artworkData` is intentionally a real, tiny 1x1 PNG
        // (see `NowPlayingFixtures.tinyPNGBase64`'s doc comment) — that's
        // exactly what the *decoder round-trip* tests want, but it decodes
        // to a perfectly valid, non-nil, one-pixel (and transparent) NSImage,
        // so the `?? syntheticArtwork()` fallback below never actually
        // fires for it. Rendered at 56pt/22pt that pixel is indistinguishable
        // from "no artwork at all" — both the expanded FlippingArtwork tile
        // and the collapsed wing's `.artwork` content read this same
        // `service.artwork`, so both silently went blank sharing this one
        // cause. Only trust a decoded image as real cover art once it's
        // bigger than that one-pixel placeholder.
        let decodedArtwork = state.artworkData.flatMap { NSImage(data: $0) }
        let artwork: NSImage
        if let decodedArtwork, decodedArtwork.size.width > 1, decodedArtwork.size.height > 1 {
            artwork = decodedArtwork
        } else {
            artwork = syntheticArtwork()
        }

        // The fixture's `timestamp`/`elapsed` are frozen at whatever moment
        // it was authored — `NowPlayingService.currentElapsed(at:)`
        // extrapolates a *playing* track forward from `timestamp`, so by the
        // time CI actually renders this (days/months later), that
        // extrapolation blows straight past `duration` and clamps to the
        // end: a full blue bar and "-0:00" remaining instead of a mid-track
        // scrubber. Rewriting both here to "now" / ~40% through the track
        // keeps the fixture's own decode path untouched while giving the
        // snapshot a believable, stable mid-playback position.
        state.timestamp = Date()
        if let duration = state.duration, duration > 0 {
            state.elapsed = duration * 0.4
        }

        service.injectPreviewState(state, artwork: artwork)
    }

    /// Deterministic stand-in cover art for renders when the fixture carries
    /// no artwork bytes: a simple two-tone gradient square, so the artwork
    /// wing, the 56pt expanded art, and the artwork-derived waveform gradient
    /// all exercise their real code paths in snapshots.
    private static func syntheticArtwork() -> NSImage {
        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.85, alpha: 1),
            ending: NSColor(calibratedRed: 0.75, green: 0.30, blue: 0.55, alpha: 1))
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        image.unlockFocus()
        return image
    }

    // MARK: - Calendar fixture

    /// Four fixture events for `expanded-calendar.png`/`expanded-duo.png`:
    /// two timed events today (each with a distinct calendar color and
    /// location), an all-day event tomorrow, and a timed event tomorrow —
    /// deliberately anchored to `calendar`'s own day boundaries (not fixed
    /// offsets from `now`) so the Today/Tomorrow split `CalendarService.
    /// groupByDay` computes lands correctly no matter what time of day CI
    /// happens to render this at.
    private static func calendarFixtureEvents(now: Date = Date(), calendar: Calendar = .current) -> [CalendarEvent] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow.addingTimeInterval(86_400)

        func at(_ hour: Int, _ minute: Int = 0, on day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        return [
            CalendarEvent(id: "fixture-design-review", title: "Design Review",
                          start: at(14, on: startOfToday), end: at(15, on: startOfToday),
                          isAllDay: false, calendarColor: .systemBlue, location: "Room 4B"),
            CalendarEvent(id: "fixture-1-1", title: "1:1 with Sam",
                          start: at(16, 30, on: startOfToday), end: at(17, on: startOfToday),
                          isAllDay: false, calendarColor: .systemOrange, location: "Zoom"),
            CalendarEvent(id: "fixture-offsite", title: "Company Offsite",
                          start: startOfTomorrow, end: startOfDayAfterTomorrow,
                          isAllDay: true, calendarColor: .systemGreen, location: nil),
            CalendarEvent(id: "fixture-dentist", title: "Dentist",
                          start: at(9, on: startOfTomorrow), end: at(10, on: startOfTomorrow),
                          isAllDay: false, calendarColor: .systemPurple, location: "Downtown Dental"),
        ]
    }

    // MARK: - Clipboard fixture

    /// Three fixture entries for `expanded-clipboard.png`: one text, one URL,
    /// one file — the three most common `ClipboardEntry.Kind`s at a glance,
    /// each with a different `capturedAt` so the row's relative-age caption
    /// reads as genuine history rather than three simultaneous copies.
    private static func clipboardFixtureEntries(now: Date = Date()) -> [ClipboardEntry] {
        [
            ClipboardEntry(id: UUID(), capturedAt: now.addingTimeInterval(-60), kind: .text,
                           preview: "Meet me at the usual spot around 6?",
                           fullString: "Meet me at the usual spot around 6?", filePaths: nil),
            ClipboardEntry(id: UUID(), capturedAt: now.addingTimeInterval(-600), kind: .url,
                           preview: "https://example.com/design-spec",
                           fullString: "https://example.com/design-spec", filePaths: nil),
            ClipboardEntry(id: UUID(), capturedAt: now.addingTimeInterval(-3_600), kind: .file,
                           preview: "quarterly-report.pdf", fullString: nil,
                           filePaths: ["/Users/fixture/quarterly-report.pdf"]),
        ]
    }

    // MARK: - Shelf fixture

    private static func makeTempShelfDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxSnapshotShelf-\(UUID().uuidString)", isDirectory: true)
    }

    /// A doc, an image, and a folder — real temporary files (not merely
    /// in-memory fixture data), copied into `store`'s own directory via the
    /// same `add(urls:)` path a real drag-and-drop drop uses, so
    /// `expanded-shelf.png` exercises the actual copy/thumbnail pipeline
    /// rather than a shortcut around it. The image is a real, tiny PNG so
    /// `QLThumbnailGenerator` has something genuine to decode; the doc and
    /// folder are plain placeholder bytes/contents — their on-disk extension
    /// (and, for the folder, its being a real directory at all) is all
    /// `NSWorkspace`'s icon fallback needs to show a sensible icon for each.
    private static func seedShelfFixtures(into store: ShelfStore) {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxSnapshotShelfSource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let docURL = sourceDir.appendingPathComponent("Quarterly Report.pdf")
        try? Data("Fixture document — not a real PDF; only the file extension matters here.".utf8).write(to: docURL)

        let imageURL = sourceDir.appendingPathComponent("Screenshot.png")
        if let pngData = Data(base64Encoded: tinyPNGBase64) {
            try? pngData.write(to: imageURL)
        }

        let folderURL = sourceDir.appendingPathComponent("Project Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? Data("placeholder".utf8).write(to: folderURL.appendingPathComponent("notes.txt"))

        store.add(urls: [docURL, imageURL, folderURL])
    }

    /// Same minimal 1x1 transparent PNG `NowPlayingFixtures` uses for its own
    /// artwork fixture (that constant is `private` to that type, so this is a
    /// deliberate, harmless duplicate rather than an exposed shared one) —
    /// real bytes a decoder can actually round-trip, not just
    /// decodable-looking text.
    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    /// Blocks (briefly) until every shelf item has a thumbnail entry — win or
    /// lose (`ShelfStore.generateThumbnail`'s own `NSWorkspace` icon fallback
    /// always populates one either way) — or `timeout` elapses, whichever
    /// comes first. `QLThumbnailGenerator`'s completion hops back via `Task {
    /// @MainActor in ... }`, so spinning the run loop in short slices (rather
    /// than one single long sleep) is what actually lets those completions
    /// land before this returns.
    private static func waitForShelfThumbnails(_ store: ShelfStore, timeout: TimeInterval = 1.5) {
        var waited: TimeInterval = 0
        while store.thumbnails.count < store.items.count && waited < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            waited += 0.1
        }
    }
}
