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
    /// `renderOffscreen` below is the same off-screen-window-and-bitmap
    /// recipe with the `exit()` left out, so this can loop over all three
    /// states and exit exactly once, itself, at the end.
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
            if renderOffscreen(rootView: root, size: panelSize, dark: dark, to: path) {
                FileHandle.standardError.write(Data("snapshot-notch: wrote \(path)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("snapshot-notch: failed to render '\(state)' to \(path)\n".utf8))
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
            seedFixtureState(into: service)
            activities.post(LiveActivity(
                kind: .nowPlaying,
                leading: .artwork,
                trailing: .iconText(systemName: "waveform", text: "1:24"),
                duration: nil,
                priority: 200))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        case "expanded":
            seedFixtureState(into: service)
            viewModel.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        default:
            break // "collapsed" — leave the view model at its initial .collapsed state
        }

        let root = NotchRootView(viewModel: viewModel, notchSize: notchSize, artworkProvider: { [weak service] in
            service?.artwork
        })
        let panelSize = NotchMetrics.panelBounds(for: notchSize.width)
        return (AnyView(root), panelSize)
    }

    /// The same off-screen NSWindow/NSHostingView/`cacheDisplay(in:to:)`
    /// recipe `OffscreenRender.capture` uses, minus that function's own
    /// `exit()` calls — see `captureAll`'s doc comment for why this couldn't
    /// just reuse it directly. Returns whether the PNG was written
    /// successfully instead of exiting the process itself.
    private static func renderOffscreen(rootView: AnyView, size: CGSize, dark: Bool, to path: String) -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        let rect = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else { return false }
        rep.size = rect.size
        hosting.cacheDisplay(in: rect, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
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
              let state = NowPlayingState(payload: payload)
        else { return }
        let artwork = state.artworkData.flatMap { NSImage(data: $0) }
        service.injectPreviewState(state, artwork: artwork)
    }
}
