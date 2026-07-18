import SwiftUI
import AppKit
import Foundation

/// Renders `NotchRootView` off-screen at a fixed size for visual review, via
/// `OffscreenRender`'s shared pipeline — for the notch panel, which (unlike
/// Settings) has no window of its own to screenshot outside a real notch Mac.
///
///   Flux --snapshot-notch <path> [dark] [collapsed|activity|expanded]
@MainActor
enum NotchSnapshot {
    /// A representative built-in notch footprint (matches recent MacBook Pro
    /// notch proportions). The panel's max-expanded size is derived from this
    /// via `NotchMetrics`, the same way `NotchWindowController.position` does.
    private static let notchSize = CGSize(width: 180, height: 32)

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
        let panelSize = CGSize(width: NotchMetrics.expandedWidth(for: notchSize.width),
                               height: NotchMetrics.expandedHeight)

        // Transparent (not opaque) window: the notch panel draws its own
        // shape over nothing, unlike Settings' real window chrome.
        OffscreenRender.capture(rootView: AnyView(root), size: panelSize, dark: dark,
                                opaque: false, label: "snapshot-notch", to: path)
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
