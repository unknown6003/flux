import AppKit
import FluxCore
import FluxUI

/// Static native rendering fixtures. This executable does not inventory apps,
/// request permissions, persist settings, run services or collect analytics.
@main struct UIProbe {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else { throw ProbeError.outputDirectoryRequired }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let sizes = [("default", SettingsWindowController.defaultSize), ("min", SettingsWindowController.minimumSize)]
            for (sizeName, size) in sizes {
            for page in SettingsPage.allCases {
                let settings = SettingsWindowController(initialPage: page) { page in
                    if page == .menuBar { return menuBarFixture() }
                    if page == .notch {
                        return NotchPreferencesController(state: .init(
                            isEnabled: true, trigger: .hover, hoverCloseDelay: 0.4, showInFullscreen: true,
                            widgets: Widget.allCases.map { .init(widget: $0, isEnabled: $0 != .clipboard) },
                            duoEnabled: false, shelfExpiry: .never, clipboardSaving: false,
                            enabledActivities: Set(NotchActivity.allCases), calendarAccess: .notAsked,
                            cameraAccess: .notAsked, accessibilityAccess: .allowed), onAction: { _ in })
                    }
                    if page == .lockScreen {
                        return LockScreenPreferencesController(state: .init(
                            isEnabled: false, showsNowPlaying: true, showsActivities: true, playsUnlockSound: true,
                            capability: .available, failureCode: nil), onAction: { _ in })
                    }
                    if page == .about {
                        return AboutPreferencesController(state: .init(version: "UI fixture", build: "fixture", update: .upToDate,
                            crashNotice: .previousSessionUnclean(cameraWasRunning: false)), onAction: { _ in })
                    }
                    return GeneralPreferencesController(state: .init(
                        launchAtLoginRequested: false, loginStatus: .disabled, hotkeysEnabled: true,
                        revealShortcut: .init(keyCode: 3, carbonModifiers: 6400),
                        notchShortcut: .init(keyCode: 45, carbonModifiers: 6400),
                        appearance: .system,
                        permissions: PermissionKind.allCases.map { .init(kind: $0, status: $0 == .accessibility ? .allowed : .notAsked) }), onAction: { _ in })
                }
                guard let window = settings.window, let content = window.contentView else { throw ProbeError.noView }
                // The frame view includes the title bar, so the page title shows in the render.
                let root = content.superview ?? content
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                // Render each screenful from top to bottom, so every row is checked at this size.
                let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTableView) }
                var offset: CGFloat = 0
                var part = 1
                while true {
                    var renderingError: (any Error)?
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        do { try render(root, to: output.appendingPathComponent("\(page.rawValue)-\(theme)-\(sizeName)-\(part).png")) }
                        catch { renderingError = error }
                    }
                    if let renderingError { throw renderingError }
                    guard let scroll, let document = scroll.documentView, part < 8 else { break }
                    let visible = scroll.contentView.bounds.height
                    let bottom = max(0, document.frame.height - visible)
                    guard offset < bottom - 1 else { break }
                    offset = min(bottom, offset + visible - 40)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    root.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    part += 1
                }
                settings.close()
            }
            }
        }
        let feedbackStates: [(String, FeedbackRatingState)] = [
            ("off", .init(collectionEnabled: false, submission: .ready)),
            ("ready", .init(collectionEnabled: true, submission: .ready)),
            ("sending", .init(collectionEnabled: true, submission: .sending)),
            ("sent", .init(collectionEnabled: true, submission: .sent)),
            ("busy", .init(collectionEnabled: true, submission: .failed(.busy))),
            ("limited", .init(collectionEnabled: true, submission: .failed(.limited))),
            ("unconfirmed", .init(collectionEnabled: true, submission: .failed(.unconfirmed))),
        ]
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, state) in feedbackStates {
                let controller = FeedbackRatingController(state: state, onAction: { _ in })
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 360, height: 220),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = controller
                let root = controller.view
                root.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: 360, height: max(180, root.fittingSize.height)))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                var failure: (any Error)?
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    do { try render(root, to: output.appendingPathComponent("feedback-\(name)-\(theme).png")) }
                    catch { failure = error }
                }
                window.close()
                if let failure { throw failure }
            }
        }
        for (name, controller) in widgetFixtures() {
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 408, height: 440),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 408, height: 440))
            window.contentView = host
            let widget = controller.view
            widget.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(widget)
            NSLayoutConstraint.activate([
                widget.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                widget.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                widget.topAnchor.constraint(equalTo: host.topAnchor),
                widget.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            window.setContentSize(NSSize(width: 408, height: 440))
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let root = host
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var failure: (any Error)?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                do { try render(root, to: output.appendingPathComponent("widget-\(name).png")) }
                catch { failure = error }
            }
            window.close()
            if let failure { throw failure }
        }
        for count in [0, 1, 4] {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let events = (0..<count).map { index in
                CalendarWidgetEvent(id: "duo-\(index)", title: "A long example meeting title", location: "Example room",
                    start: now.addingTimeInterval(Double(index) * 3600),
                    end: now.addingTimeInterval(Double(index + 1) * 3600), isAllDay: false)
            }
            let geometry = NotchGeometry(screenFrame: .init(x: 0, y: 0, width: 1728, height: 1117),
                cameraWidth: 180, topInset: 33)
            let controller = NotchPanelController(widgets: [.nowPlaying, .calendar], geometry: geometry) { widget in
                if widget == .calendar {
                    return CalendarWidgetController(state: .events(today: events, tomorrow: []), onAction: { _ in })
                }
                return NowPlayingWidgetController(state: .init(status: .playing, title: "An example song title",
                    artist: "Example artist", elapsed: 65, duration: 240, canGoPrevious: true, canGoNext: true), onAction: { _ in })
            }
            controller.setDuo(count > 0)
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 440, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.contentViewController = controller
            controller.view.widthAnchor.constraint(equalToConstant: 440).isActive = true
            controller.show(.nowPlaying)
            window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try render(controller.view, to: output.appendingPathComponent("duo-\(count)-events.png"))
            controller.dismiss()
            window.close()
        }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let media = NowPlayingWidgetState(status: .playing, title: "An example song title", artist: "Example artist",
                elapsed: 65, duration: 240)
            let caption = LockScreenActivityCaption(symbolName: "timer", text: "Timer, 1:05 remaining")
            let states: [(String, LockScreenContentState)] = [
                ("media", .init(media: media)), ("media-caption", .init(media: media, activity: caption)),
                ("caption", .init(activity: caption)), ("empty", .empty)
            ]
            for (name, state) in states {
                let controller = LockScreenContentController(state: state, onAction: { _ in })
                let size = state.isEmpty ? NSSize(width: 348, height: 164) : controller.preferredSize
                let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let host = NSView(frame: .init(origin: .zero, size: size))
                window.contentView = host
                let card = controller.view
                host.addSubview(card)
                card.frame = .init(origin: .zero, size: controller.preferredSize)
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try render(host, to: output.appendingPathComponent("lock-\(name)-\(theme).png"))
                window.close()
            }
        }
        for notched in [false, true] {
            let geometry = NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
                                         cameraWidth: notched ? 180 : 0, topInset: 33)
            let samples: [(String, ActivityItem?)] = [
                ("idle", nil),
                ("battery", try ActivityItem(kind: .battery, leading: .symbol("battery.25percent"),
                    trailing: .text("18%"), priority: 10, tint: .warning, duration: 5)),
                ("timer", try ActivityItem(kind: .timer, leading: .gauge(value: 0.6, symbol: "timer"),
                    trailing: .text("1:05"), priority: 10, duration: nil)),
                ("media", try ActivityItem(kind: .nowPlaying, leading: .artwork,
                    trailing: .symbol("waveform"), priority: 1, duration: nil)),
                ("volume", try ActivityItem(kind: .soundHUD, leading: .symbol("speaker.wave.2"),
                    trailing: .soundGauge(value: 0.6, symbol: "speaker.wave.2"), priority: 10, duration: 2))
            ]
            for (name, item) in samples {
                let controller = CompactNotchController(state: .init(geometry: geometry, currentActivity: item,
                    queueCount: item == nil ? 0 : 2, restorableCount: 1), onAction: { _ in })
                let window = NSWindow(contentRect: NSRect(origin: .init(x: -10_000, y: -10_000), size: controller.preferredSize),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.backgroundColor = .clear
                window.contentViewController = controller
                window.setContentSize(controller.preferredSize)
                window.orderFrontRegardless()
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try render(controller.view, to: output.appendingPathComponent("compact-\(notched ? "notch" : "flat")-\(name).png"))
                window.close()
            }
        }
    }

    @MainActor private static func widgetFixtures() -> [(String, NSViewController)] {
        var fixtures: [(String, NSViewController)] = []
        let source = ApplicationID(rawValue: "org.fluxfixture.player")!
        for (name, status) in [("playing", NowPlayingWidgetStatus.playing), ("paused", .paused), ("empty", .empty), ("noAccess", .noAccess), ("loading", .loading)] {
            fixtures.append(("nowPlaying-" + name, NowPlayingWidgetController(state: .init(
                status: status, title: "A long track title that still leaves room for the player controls",
                artist: "Example Artist", sources: [.init(id: source, name: "Example Player")],
                selectedSource: source, elapsed: 65, duration: 240), onAction: { _ in })))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events: [CalendarWidgetEvent] = (0..<6).map { (index: Int) -> CalendarWidgetEvent in
            let title = index == 0 ? "A long event name that should fit in the narrow notch panel" : "Example event \(index)"
            let start = now.addingTimeInterval(Double(index) * 3600)
            let end = start.addingTimeInterval(1800)
            let color = CalendarWidgetColor(red: 0.2, green: 0.6, blue: 0.9)
            return CalendarWidgetEvent(id: "fixture-\(index)", title: title, location: "Example room",
                                       start: start, end: end, isAllDay: index == 0, color: color)
        }
        for (name, state) in [("events", CalendarWidgetState.events(today: events, tomorrow: Array(events.prefix(2)))),
                              ("empty", .events(today: [], tomorrow: [])), ("permission", .needsPermission), ("unavailable", .unavailable), ("loading", .loading)] {
            fixtures.append(("calendar-" + name, CalendarWidgetController(state: state, onAction: { _ in })))
        }
        for (name, status) in [("starting", MirrorWidgetStatus.starting), ("running", .running), ("permission", .needsPermission),
                               ("unavailable", .unavailable), ("interrupted", .interrupted), ("failed", .failed)] {
            fixtures.append(("mirror-" + name, MirrorWidgetController(status: status, preview: nil, onAction: { _ in })))
        }
        let files = (0..<6).map { index in
            FileShelfWidgetItem(id: UUID(), name: index == 0 ? "An example file with a long name.pdf" : "Example file \(index).txt")
        }
        for (name, state) in [("files", FileShelfWidgetState(items: files)), ("empty", .init()),
                              ("loading", .init(status: .loading)), ("busy", .init(items: files, status: .busy)), ("failed", .init(status: .failed))] {
            fixtures.append(("shelf-" + name, FileShelfWidgetController(state: state, onAction: { _ in })))
        }
        let clips = [ClipboardWidgetItem(id: UUID(), preview: "Example copied text", kind: .text),
                     .init(id: UUID(), preview: "https://example.com", kind: .url, link: URL(string: "https://example.com")),
                     .init(id: UUID(), preview: "#AABBCC", kind: .color, color: .init(red: 0.67, green: 0.73, blue: 0.8)),
                     .init(id: UUID(), preview: "Image 2000 × 1000", kind: .image, hasPayload: false),
                     .init(id: UUID(), preview: "Example file.txt", kind: .file)]
        fixtures.append(("clipboard-rows", ClipboardWidgetController(state: .init(items: clips), onAction: { _ in })))
        fixtures.append(("clipboard-empty", ClipboardWidgetController(state: .init(), onAction: { _ in })))
        fixtures.append(("clipboard-copied", ClipboardWidgetController(state: .init(items: clips, copiedID: clips[0].id), onAction: { _ in })))
        return fixtures
    }

    @MainActor private static func menuBarFixture() -> NSViewController {
        let rows = [
            ("org.fluxfixture.player", "Example Player", MenuBarGroup.shown),
            ("org.fluxfixture.calendar", "Example Calendar with a wide label", .hidden),
            ("org.fluxfixture.sync", "Example Sync", .alwaysHidden),
            ("com.apple.controlcenter", "Control Center", .shown)
        ].map { raw, name, group in
            MenuBarAppRow(id: ApplicationID(rawValue: raw)!, name: name,
                          icon: NSImage(systemSymbolName: "app", accessibilityDescription: nil),
                          group: group)
        }
        let actions = MenuBarPageActions(assign: { _, _ in }, beginArrange: {}, endArrange: {},
            showRealIcons: {}, refresh: {}, openAccessibilitySettings: {}, checkAccessibility: {}, reviewIdentity: { _ in }, setOption: { _ in })
        return MenuBarPreferencesController(state: .init(mode: .perApplication, rows: rows), actions: actions)
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor private static func render(_ view: NSView, to destination: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ProbeError.noBitmap }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // cacheDisplay omits the NSWindow's background. Composite that same
        // native color behind the view, so transparent pixels do not render
        // as black and hide light-appearance labels in the artifact viewer.
        guard let source = bitmap.cgImage,
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProbeError.noBitmap }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setFillColor((view.window?.backgroundColor ?? NSColor.windowBackgroundColor).cgColor)
        context.fill(bounds)
        context.draw(source, in: bounds)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ProbeError.noBitmap }
        try png.write(to: destination, options: .atomic)
    }

    private enum ProbeError: Error { case outputDirectoryRequired, noView, noBitmap }
}
