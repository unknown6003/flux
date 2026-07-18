import SwiftUI
import AppKit
import Foundation

/// Renders `NotchRootView` off-screen at a fixed size for visual review —
/// mirrors `SettingsSnapshot`'s recipe (an off-screen window +
/// `cacheDisplay(in:to:)`) but for the notch panel, which (unlike Settings)
/// has no window of its own to screenshot outside a real notch Mac.
///
///   Flux --snapshot-notch <path> [dark] [collapsed|activity|expanded]
@MainActor
enum NotchSnapshot {
    /// A representative built-in notch footprint (matches recent MacBook Pro
    /// notch proportions) and the panel's max-expanded size, computed the
    /// same way `NotchWindowController.position` does.
    private static let notchSize = CGSize(width: 180, height: 32)
    private static let panelSize = CGSize(width: max(180 + 440, 600), height: 280)

    static func capture(to path: String, dark: Bool, state: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        app.appearance = appearance

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
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)

        // Let SwiftUI complete layout and an initial draw pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        let rect = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else {
            FileHandle.standardError.write(Data("snapshot-notch: no bitmap rep\n".utf8))
            exit(1)
        }
        rep.size = rect.size
        hosting.cacheDisplay(in: rect, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-notch: png encode failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot-notch wrote \(path) (\(Int(panelSize.width))x\(Int(panelSize.height)))\n".utf8))
        exit(0)
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
