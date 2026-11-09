import AppKit
import SwiftUI

// Reference renderer for the 0.21.35 notch. It is not a SwiftPM target:
// Scripts/rebuild/render_notch_comparison.py compiles it with every file in
// Sources/Flux except main.swift, so it uses the old views and services
// unchanged. It renders the states that `Flux --snapshot-notch all` does not
// cover, with the same fixtures, size and offscreen path. It never starts a
// camera: Mirror uses `CameraService(forcingUnavailable: true)`.
//
//     LegacyNotchRender <output-dir>

@main
@MainActor
enum LegacyNotchRender {
    static let notchSize = CGSize(width: 180, height: 32)

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: LegacyNotchRender <output-dir>\n".utf8))
            exit(2)
        }
        let output = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        let activities: [(String, LiveActivity)] = [
            ("battery-charging-activity", LiveActivity(kind: .battery, leading: .icon(systemName: NotchActivityRouter.batterySymbol(percent: 80, charging: true)),
                                                      trailing: .text("80%"), duration: 4, priority: 200)),
            ("battery-unplugged-activity", LiveActivity(kind: .battery, leading: .icon(systemName: NotchActivityRouter.batterySymbol(percent: 80, charging: false)),
                                                       trailing: .text("80%"), duration: 4, priority: 200)),
            ("battery-low-activity", LiveActivity(kind: .battery, leading: .icon(systemName: NotchActivityRouter.batterySymbol(percent: 9, charging: false)),
                                                 trailing: .text("9%"), duration: nil, priority: 200, tint: .warning)),
            ("bluetooth-activity", LiveActivity(kind: .bluetoothDevice, leading: .icon(systemName: "airpodspro"),
                                               trailing: .iconText(systemName: NotchActivityRouter.batterySymbol(percent: 80, charging: false), text: "80%"),
                                               duration: 4, priority: 100)),
            ("bluetooth-disconnected-activity", LiveActivity(kind: .bluetoothDevice, leading: .icon(systemName: "headphones"),
                                                            trailing: .text("Disconnected"), duration: 4, priority: 100)),
            ("calendar-event-activity", LiveActivity(kind: .calendarEvent, leading: .icon(systemName: "calendar"),
                                                    trailing: .text("Design Review in 8m"), duration: nil, priority: 120)),
            ("overflow-activity", LiveActivity(kind: .menuBarOverflow, leading: .icon(systemName: "exclamationmark.triangle.fill"),
                                              trailing: .text("3"), duration: nil, priority: 150)),
            ("shelf-drop-activity", LiveActivity(kind: .shelfDrop, leading: .icon(systemName: "tray.and.arrow.down.fill"),
                                                trailing: .text("Added 3"), duration: 2.5, priority: 120)),
            ("timer-done-activity", NotchActivityRouter.timerCompletionActivity(label: TimerActivity.defaultLabel(minutes: 5))),
            ("timer-paused-activity", LiveActivity(kind: .timer, leading: .icon(systemName: "pause.circle"),
                                                  trailing: .text("4:31"), duration: nil, priority: 110)),
        ]
        var ok = true
        for (name, activity) in activities {
            ok = render(name, to: output) { _, center, _ in center.post(activity) } && ok
        }
        ok = render("expanded-nowPlaying-paused", to: output) { model, _, services in
            model.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            seed(services.nowPlaying, playing: false)
        } && ok
        ok = render("empty-nowPlaying", to: output) { model, _, services in
            model.expand(.nowPlaying)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            services.nowPlaying.injectPreviewState(nil)
        } && ok
        ok = render("permission-calendar", to: output) { model, _, services in
            model.expand(.calendar)
            services.permissions.injectPreviewStatus(.calendar, .notDetermined)
        } && ok
        ok = render("denied-calendar", to: output) { model, _, services in
            model.expand(.calendar)
            services.permissions.injectPreviewStatus(.calendar, .denied)
        } && ok
        ok = render("empty-clipboard", to: output) { model, _, _ in model.expand(.clipboard) } && ok
        ok = render("permission-mirror", to: output) { model, _, services in
            model.expand(.mirror)
            services.permissions.injectPreviewStatus(.camera, .notDetermined)
        } && ok
        ok = render("denied-mirror", to: output) { model, _, services in
            model.expand(.mirror)
            services.permissions.injectPreviewStatus(.camera, .denied)
        } && ok
        exit(ok ? 0 : 1)
    }

    struct Services {
        let nowPlaying: NowPlayingService
        let permissions: PermissionCenter
    }

    static func render(_ name: String, to output: String,
                       setup: (NotchViewModel, LiveActivityCenter, Services) -> Void) -> Bool {
        let registry = NotchWidgetRegistry()
        let activities = LiveActivityCenter()
        let nowPlaying = NowPlayingService()
        let shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxLegacyShelf-\(UUID().uuidString)", isDirectory: true)
        let permissions = PermissionCenter()
        registry.register(NowPlayingWidget(service: nowPlaying))
        registry.register(ShelfWidget(store: ShelfStore(directory: shelfDirectory)))
        registry.register(CalendarWidget(service: CalendarService(), permissions: permissions))
        registry.register(MirrorWidget(service: CameraService(forcingUnavailable: true), permissions: permissions))
        registry.register(ClipboardWidget(monitor: ClipboardMonitor()))
        registry.order = WidgetID.allCases
        let model = NotchViewModel(registry: registry, activities: activities)
        setup(model, activities, Services(nowPlaying: nowPlaying, permissions: permissions))
        let root = NotchRootView(viewModel: model, notchSize: notchSize, artworkProvider: { [weak nowPlaying] in
            nowPlaying?.artwork
        }).environment(\.isSnapshotRender, true)
        let result = OffscreenRender.render(rootView: AnyView(root), size: NotchMetrics.panelBounds(for: notchSize.width),
                                            dark: true, opaque: false, label: "legacy-notch",
                                            to: (output as NSString).appendingPathComponent(name + ".png"))
        try? FileManager.default.removeItem(at: shelfDirectory)
        return result
    }

    /// The `NotchSnapshot` media fixture, optionally paused.
    static func seed(_ service: NowPlayingService, playing: Bool) {
        guard let data = NowPlayingFixtures.streamFullSnapshotJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadDict = object["payload"] as? [String: Any],
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict),
              let payload = try? JSONDecoder().decode(MediaRemoteAdapterPayload.self, from: payloadData),
              var state = NowPlayingState(payload: payload) else { return }
        let size = NSSize(width: 120, height: 120)
        let artwork = NSImage(size: size)
        artwork.lockFocus()
        NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.85, alpha: 1),
                   ending: NSColor(calibratedRed: 0.75, green: 0.30, blue: 0.55, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)
        artwork.unlockFocus()
        state.timestamp = Date()
        if let duration = state.duration, duration > 0 { state.elapsed = duration * 0.4 }
        state.isPlaying = playing
        service.injectPreviewState(state, artwork: artwork)
    }
}
