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

    /// Batch mode behind CI's "Render notch snapshots" step: renders the
    /// three states the M7 redesign most needs a human/PR-bot glance at —
    /// collapsed (must look perfectly seamless — no shadow, no visible
    /// panel), activity (the monochrome wings), and the Now Playing widget
    /// expanded (the new compact Alcove-scale panel, overshoot spring
    /// notwithstanding since this is a single still frame) — into fixed
    /// filenames under `dir`, in one process launch.
    ///
    /// Deliberately does NOT reuse `capture(to:dark:state:)` for this: that
    /// function ends in `OffscreenRender.capture`, which always calls
    /// `exit()` once it's written its one PNG (every other snapshot flag is
    /// single-shot, so that's the right contract there) — calling it three
    /// times in a row would just exit the process after the first file.
    /// `OffscreenRender.render` — the same recipe with the `exit()` left out —
    /// is what this loops over instead, so all three states render and this
    /// function exits exactly once, itself, at the end.
    ///
    /// A fourth `duo.png` (Now Playing + Calendar side by side, M7) was
    /// considered but deliberately left out: unlike `NowPlayingService`
    /// (`injectPreviewState`), `CalendarService.upcoming` has no injection
    /// seam — it's `@Published private(set)`, fed only by a real
    /// `EKEventStore` fetch — and `CalendarWidget`'s expanded view renders
    /// through `PermissionGatedView`, which would show the permission
    /// explainer rather than an agenda without a live (granted) `Permission
    /// Center` status to match. Wiring both up would mean adding fixture-
    /// injection surface to two more types purely for this one snapshot,
    /// rather than the trivial "register a widget + set a state" this
    /// function's other three cases needed — left for a future pass instead
    /// of forcing that scope in here.
    static func captureAll(to dir: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let states: [(state: String, file: String)] = [
            ("collapsed", "collapsed.png"),
            ("activity", "activity.png"),
            ("expanded", "expanded-nowPlaying.png"),
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
    /// view model per call (so no state leaks between `captureAll`'s three
    /// iterations), seeded and transitioned to `state`, plus the fixed panel
    /// bounds (`NotchMetrics.panelBounds`) that state should render at.
    private static func buildRoot(for state: String) -> (AnyView, CGSize) {
        let registry = NotchWidgetRegistry()
        let service = NowPlayingService()
        let widget = NowPlayingWidget(service: service)
        registry.register(widget)
        registry.order = [.nowPlaying]

        let activities = LiveActivityCenter()
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
            seedFixtureState(into: service)
        case "expanded":
            viewModel.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            seedFixtureState(into: service)
        default:
            break // "collapsed" — leave the view model at its initial .collapsed state
        }

        let root = NotchRootView(viewModel: viewModel, notchSize: notchSize, artworkProvider: { [weak service] in
            service?.artwork
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
}
