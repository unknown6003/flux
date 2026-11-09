import AppKit
import FluxCore
import FluxUI
import QuickLookThumbnailing
import SwiftUI

/// Renders the native notch with the 0.21.35 snapshot fixtures, at the same
/// size and with the same offscreen path as `Flux --snapshot-notch`, then
/// compares each image with the 0.21.35 render of the same state.
///
///     swift run FluxNotchProbe <output-dir> [<reference-dir> ...]
///
/// Writes `<output-dir>/new/<state>.png`, and for each state that has a
/// reference `<output-dir>/compare/<state>.png` (old | new | diff) plus
/// `<output-dir>/report.json`. It opens no hardware, reads no pasteboard and
/// never shows a window on screen.
@main struct NotchProbe {
    static let notchSize = CGSize(width: 180, height: 32)
    /// Channel difference, out of 255, that counts a pixel as different.
    static let tolerance = 8

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: FluxNotchProbe <output-dir> [<reference-dir> ...]\n".utf8))
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let references = arguments.dropFirst(2).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let newDirectory = output.appendingPathComponent("new", isDirectory: true)
        let compareDirectory = output.appendingPathComponent("compare", isDirectory: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compareDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        var report: [[String: Any]] = []
        for fixture in try fixtures() {
            let destination = newDirectory.appendingPathComponent(fixture.name + ".png")
            // Built just before its render, so a playing clock starts from now.
            try render(try fixture.build(), size: fixture.size, to: destination)
            fixture.cleanup()
            var entry: [String: Any] = ["state": fixture.name, "new": destination.path]
            if let reference = references.map({ $0.appendingPathComponent(fixture.name + ".png") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let comparison = try compare(old: reference, new: destination,
                                             to: compareDirectory.appendingPathComponent(fixture.name + ".png"))
                entry["old"] = reference.path
                entry["compare"] = compareDirectory.appendingPathComponent(fixture.name + ".png").path
                entry["pixels"] = comparison.pixels
                entry["differingPixels"] = comparison.differing
                entry["differingPercent"] = comparison.percent
                entry["exactDifferingPercent"] = comparison.exactPercent
                entry["sameSize"] = comparison.sameSize
                print(String(format: "%-28@ %6.2f%% differ (tolerance %d), %6.2f%% exact", fixture.name as NSString,
                             comparison.percent, tolerance, comparison.exactPercent))
            } else {
                entry["old"] = NSNull()
                print(String(format: "%-28@ new only", fixture.name as NSString))
            }
            report.append(entry)
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("report.json"))
    }

    // MARK: Fixtures

    struct Fixture {
        var name: String
        var build: @MainActor () throws -> AnyView
        var size: CGSize
        var cleanup: @MainActor () -> Void = {}
    }

    @MainActor static func fixtures() throws -> [Fixture] {
        var list: [Fixture] = []
        let panel = NotchMetrics.panelBounds(for: notchSize.width)

        func notch(_ name: String, widgets: [FluxCore.Widget] = FluxCore.Widget.allCases,
                   setup: @escaping @MainActor (NotchViewModel, inout [FluxCore.Widget: NSViewController]) throws -> Void) {
            list.append(Fixture(name: name, build: {
                let model = NotchViewModel()
                var controllers: [FluxCore.Widget: NSViewController] = [:]
                model.setWidgets(widgets)
                try setup(model, &controllers)
                let held = controllers
                model.widgetContent = { widget in (held[widget] as? NotchContentProviding)?.notchContent() }
                return AnyView(NotchRootView(viewModel: model, notchSize: notchSize).environment(\.isSnapshotRender, true))
            }, size: panel))
        }

        func activity(_ kind: ActivityKind, _ leading: ActivityWing, _ trailing: ActivityWing,
                      priority: Int, tint: ActivityTint = .normal) throws -> ActivityItem {
            try ActivityItem(kind: kind, leading: leading, trailing: trailing, priority: priority, tint: tint, duration: nil)
        }

        // Closed and compact (0.21.35 NotchSnapshot states).
        notch("collapsed") { _, _ in }
        notch("activity") { model, _ in
            model.setActivity(try activity(.nowPlaying, .artwork, .symbolText(symbol: "waveform", text: "1:24"), priority: 200),
                              artwork: syntheticArtwork())
        }
        notch("timer-activity") { model, _ in
            model.setActivity(try activity(.timer, .symbol("timer"), .text("4:31"), priority: 110), artwork: nil)
        }
        notch("sound-activity") { model, _ in
            model.setActivity(try activity(.soundHUD, .none, .soundGauge(value: 0.6, symbol: "speaker.wave.2.fill"), priority: 300),
                              artwork: nil)
        }
        notch("mute-activity") { model, _ in
            model.setActivity(try activity(.soundHUD, .none, .soundGauge(value: 0.6, symbol: "speaker.slash.fill"), priority: 300),
                              artwork: nil)
        }
        // Every other live activity, as the native coordinator posts it.
        let extra: [(String, ActivityItem)] = [
            ("battery-charging-activity", try activity(.battery, .symbol("battery.100.bolt"), .text("80%"), priority: 200)),
            ("battery-unplugged-activity", try activity(.battery, .symbol("battery.75"), .text("80%"), priority: 200)),
            ("battery-low-activity", try activity(.battery, .symbol("battery.0"), .text("9%"), priority: 200, tint: .warning)),
            ("bluetooth-activity", try activity(.bluetoothDevice, .symbol("airpodspro"),
                                                .symbolText(symbol: "battery.75", text: "80%"), priority: 100)),
            ("bluetooth-disconnected-activity", try activity(.bluetoothDevice, .symbol("headphones"), .text("Disconnected"), priority: 100)),
            ("calendar-event-activity", try activity(.calendarEvent, .symbol("calendar"), .text("Design Review in 8m"), priority: 120)),
            ("overflow-activity", try activity(.menuBarOverflow, .symbol("exclamationmark.triangle.fill"), .text("3"), priority: 150)),
            ("shelf-drop-activity", try activity(.shelfDrop, .symbol("tray.and.arrow.down.fill"), .text("Added 3"), priority: 120)),
            ("timer-done-activity", try activity(.timer, .symbol("timer"), .text("5 min done"), priority: 250)),
            ("timer-paused-activity", try activity(.timer, .symbol("pause.circle"), .text("4:31"), priority: 110)),
        ]
        for (name, item) in extra {
            notch(name) { model, _ in model.setActivity(item, artwork: nil) }
        }

        // Open widget pages.
        notch("expanded-nowPlaying") { model, controllers in
            controllers[.nowPlaying] = NowPlayingWidgetController(state: mediaFixture(), onAction: { _ in })
            model.expand(.nowPlaying)
        }
        notch("expanded-nowPlaying-paused") { model, controllers in
            var state = mediaFixture()
            state.status = .paused
            controllers[.nowPlaying] = NowPlayingWidgetController(state: state, onAction: { _ in })
            model.expand(.nowPlaying)
        }
        notch("empty-nowPlaying") { model, controllers in
            controllers[.nowPlaying] = NowPlayingWidgetController(state: .empty, onAction: { _ in })
            model.expand(.nowPlaying)
        }
        let shelfFiles = try shelfFixture()
        notch("expanded-shelf") { model, controllers in
            controllers[.shelf] = FileShelfWidgetController(state: .init(items: shelfFiles.items), onAction: { _ in })
            model.expand(.shelf)
        }
        list[list.count - 1].cleanup = { try? FileManager.default.removeItem(at: shelfFiles.directory) }
        notch("empty-shelf") { model, controllers in
            controllers[.shelf] = FileShelfWidgetController(state: .init(), onAction: { _ in })
            model.expand(.shelf)
        }
        notch("expanded-calendar") { model, controllers in
            controllers[.calendar] = CalendarWidgetController(state: calendarFixture(), onAction: { _ in })
            model.expand(.calendar)
        }
        notch("empty-calendar") { model, controllers in
            controllers[.calendar] = CalendarWidgetController(state: .events(today: [], tomorrow: []), onAction: { _ in })
            model.expand(.calendar)
        }
        notch("permission-calendar") { model, controllers in
            controllers[.calendar] = CalendarWidgetController(state: .needsPermission, onAction: { _ in })
            model.expand(.calendar)
        }
        notch("denied-calendar") { model, controllers in
            controllers[.calendar] = CalendarWidgetController(state: .unavailable, onAction: { _ in })
            model.expand(.calendar)
        }
        notch("expanded-clipboard") { model, controllers in
            controllers[.clipboard] = ClipboardWidgetController(state: clipboardFixture(), onAction: { _ in })
            model.expand(.clipboard)
        }
        notch("empty-clipboard") { model, controllers in
            controllers[.clipboard] = ClipboardWidgetController(state: .init(), onAction: { _ in })
            model.expand(.clipboard)
        }
        notch("expanded-mirror") { model, controllers in
            controllers[.mirror] = MirrorWidgetController(status: .unavailable, preview: nil, onAction: { _ in })
            model.expand(.mirror)
        }
        notch("starting-mirror") { model, controllers in
            controllers[.mirror] = MirrorWidgetController(status: .starting, preview: nil, onAction: { _ in })
            model.expand(.mirror)
        }
        notch("permission-mirror") { model, controllers in
            controllers[.mirror] = MirrorWidgetController(status: .needsPermission, preview: nil, onAction: { _ in })
            model.expand(.mirror)
        }
        notch("denied-mirror") { model, controllers in
            controllers[.mirror] = MirrorWidgetController(status: .denied, preview: nil, onAction: { _ in })
            model.expand(.mirror)
        }
        notch("expanded-duo") { model, controllers in
            controllers[.nowPlaying] = NowPlayingWidgetController(state: mediaFixture(), onAction: { _ in })
            controllers[.calendar] = CalendarWidgetController(state: calendarFixture(), onAction: { _ in })
            model.duoActive = true
            model.expand(.nowPlaying)
        }

        // Lock screen: the silhouette under the card, as the old fixture drew it.
        let timerCaption = LockScreenActivityCaption(symbolName: "timer", text: "2 min")
        for (name, state) in [("lockscreen", LockScreenContentState(media: mediaFixture(), activity: timerCaption)),
                              ("lockscreen-media-only", LockScreenContentState(media: mediaFixture())),
                              ("lockscreen-activity-only", LockScreenContentState(activity: timerCaption))] {
            let size = state.preferredSize
            list.append(Fixture(name: name, build: {
                var fresh = state
                if fresh.media != nil { fresh.media = mediaFixture() }
                let card = LockScreenContentController(state: fresh, onAction: { _ in })
                card.isFixtureRender = true
                return AnyView(LockComposite(card: card, size: size, notchSize: notchSize))
            }, size: size))
        }
        return list
    }

    @MainActor static func mediaFixture() -> NowPlayingWidgetState {
        // The 0.21.35 fixture: Sunday Morning, 167.5 s, 40% elapsed, Music.
        NowPlayingWidgetState(status: .playing, title: "Sunday Morning", artist: "The Velvet Underground",
                              artwork: syntheticArtwork(), selectedSource: ApplicationID(rawValue: "com.apple.Music"),
                              elapsed: 167.5 * 0.4, duration: 167.5)
    }

    @MainActor static func syntheticArtwork() -> NSImage {
        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.85, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.75, green: 0.30, blue: 0.55, alpha: 1))
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        image.unlockFocus()
        return image
    }

    @MainActor static func calendarFixture(now: Date = Date()) -> CalendarWidgetState {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        let after = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow.addingTimeInterval(86_400)
        func at(_ hour: Int, _ minute: Int = 0, on day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func color(_ system: NSColor) -> CalendarWidgetColor {
            var resolved = NSColor.black
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                resolved = system.usingColorSpace(.sRGB) ?? .black
            }
            return CalendarWidgetColor(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
        }
        return .events(today: [
            CalendarWidgetEvent(id: "fixture-design-review", title: "Design Review", location: "Room 4B",
                                start: at(14, on: today), end: at(15, on: today), color: color(.systemBlue)),
            CalendarWidgetEvent(id: "fixture-1-1", title: "1:1 with Sam", location: "Zoom",
                                start: at(16, 30, on: today), end: at(17, on: today), color: color(.systemOrange)),
        ], tomorrow: [
            CalendarWidgetEvent(id: "fixture-offsite", title: "Company Offsite", start: tomorrow, end: after,
                                isAllDay: true, color: color(.systemGreen)),
            CalendarWidgetEvent(id: "fixture-dentist", title: "Dentist", location: "Downtown Dental",
                                start: at(9, on: tomorrow), end: at(10, on: tomorrow), color: color(.systemPurple)),
        ])
    }

    @MainActor static func clipboardFixture(now: Date = Date()) -> ClipboardWidgetState {
        ClipboardWidgetState(items: [
            ClipboardWidgetItem(id: UUID(), preview: "Meet me at the usual spot around 6?", kind: .text,
                                capturedAt: now.addingTimeInterval(-60)),
            ClipboardWidgetItem(id: UUID(), preview: "https://example.com/design-spec", kind: .url,
                                link: URL(string: "https://example.com/design-spec"), capturedAt: now.addingTimeInterval(-600)),
            ClipboardWidgetItem(id: UUID(), preview: "quarterly-report.pdf", kind: .file,
                                capturedAt: now.addingTimeInterval(-3_600)),
        ])
    }

    /// The 0.21.35 shelf fixture files, with QuickLook thumbnails made the
    /// same way the old store and the native coordinator make them.
    @MainActor static func shelfFixture() throws -> (items: [FileShelfWidgetItem], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxNotchProbeShelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let doc = directory.appendingPathComponent("Quarterly Report.pdf")
        try Data("Fixture document — not a real PDF; only the file extension matters here.".utf8).write(to: doc)
        let image = directory.appendingPathComponent("Screenshot.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")?
            .write(to: image)
        let folder = directory.appendingPathComponent("Project Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        // Newest first, as both stores sort.
        let urls = [folder, image, doc]
        var thumbnails: [URL: NSImage] = [:]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for url in urls {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: scale,
                                                       representationTypes: .thumbnail)
            let box = ThumbnailBox()
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                box.set(representation?.nsImage)
            }
            let deadline = Date().addingTimeInterval(3)
            while !box.done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            thumbnails[url] = box.image ?? NSWorkspace.shared.icon(forFile: url.path)
        }
        let items = urls.map { url in
            FileShelfWidgetItem(id: UUID(), name: url.lastPathComponent, image: thumbnails[url], dragURL: url,
                                addedAt: Date())
        }
        return (items, directory)
    }

    // MARK: Rendering (the 0.21.35 OffscreenRender path)

    @MainActor static func render(_ root: AnyView, size: CGSize, to destination: URL) throws {
        let appearance = NSAppearance(named: .darkAqua)!
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        let rect = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else { throw ProbeError.noBitmap }
        rep.size = rect.size
        hosting.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ProbeError.noBitmap }
        try png.write(to: destination)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    // MARK: Comparison

    struct Comparison {
        var pixels: Int
        var differing: Int
        var exact: Int
        var sameSize: Bool
        var percent: Double { pixels == 0 ? 100 : Double(differing) * 100 / Double(pixels) }
        var exactPercent: Double { pixels == 0 ? 100 : Double(exact) * 100 / Double(pixels) }
    }

    /// RGBA pixels of a PNG in sRGB, top row first.
    static func pixels(_ url: URL) throws -> (width: Int, height: Int, data: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProbeError.unreadable(url.path) }
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ProbeError.unreadable(url.path) }
        return (width, height, data)
    }

    /// Counts pixels whose largest channel delta is above `tolerance` over the
    /// union of both sizes, and writes old | new | diff side by side. Diff
    /// pixels are red, matching pixels are a dim copy of the old image.
    static func compare(old: URL, new: URL, to destination: URL) throws -> Comparison {
        let a = try pixels(old), b = try pixels(new)
        let width = max(a.width, b.width), height = max(a.height, b.height)
        var diff = [UInt8](repeating: 0, count: width * height * 4)
        var differing = 0, exact = 0
        func pixel(_ image: (width: Int, height: Int, data: [UInt8]), _ x: Int, _ y: Int) -> [Int] {
            guard x < image.width, y < image.height else { return [0, 0, 0, 0] }
            let i = (y * image.width + x) * 4
            return [Int(image.data[i]), Int(image.data[i + 1]), Int(image.data[i + 2]), Int(image.data[i + 3])]
        }
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(a, x, y), q = pixel(b, x, y)
                let delta = zip(p, q).map { abs($0 - $1) }.max() ?? 0
                let i = (y * width + x) * 4
                if delta > 0 { exact += 1 }
                if delta > tolerance {
                    differing += 1
                    diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0; diff[i + 3] = 255
                } else {
                    diff[i] = UInt8(p[0] / 4); diff[i + 1] = UInt8(p[1] / 4); diff[i + 2] = UInt8(p[2] / 4)
                    diff[i + 3] = UInt8(max(p[3], 60))
                }
            }
        }
        // Side by side on a mid-grey ground, so black panels stay visible.
        let gap = 16
        let sheetWidth = width * 3 + gap * 4, sheetHeight = height + gap * 2
        guard let sheet = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProbeError.noBitmap }
        sheet.setFillColor(CGColor(gray: 0.55, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        for (index, image) in [(a.width, a.height, a.data), (b.width, b.height, b.data), (width, height, diff)].enumerated() {
            var bytes = image.2
            let made: CGImage? = bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: image.0, height: image.1, bitsPerComponent: 8,
                          bytesPerRow: image.0 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            guard let made else { continue }
            let x = gap + index * (width + gap)
            sheet.draw(made, in: CGRect(x: x, y: gap + (height - image.1), width: image.0, height: image.1))
        }
        guard let image = sheet.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ProbeError.noBitmap }
        try png.write(to: destination)
        return Comparison(pixels: width * height, differing: differing, exact: exact,
                          sameSize: a.width == b.width && a.height == b.height)
    }

    enum ProbeError: Error { case noBitmap, unreadable(String) }
}

/// One thumbnail result, written once from QuickLook's queue.
private final class ThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NSImage?
    private var finished = false
    var image: NSImage? { lock.withLock { stored } }
    var done: Bool { lock.withLock { finished } }
    func set(_ value: NSImage?) { lock.withLock { stored = value; finished = true } }
}

/// The lock fixture: the notch silhouette top-centered under the card.
private struct LockComposite: NSViewRepresentable {
    let card: LockScreenContentController
    let size: CGSize
    let notchSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let silhouette = LockScreenSilhouetteView(notchSize: notchSize)
        let shape = silhouette.preferredSize
        silhouette.frame = NSRect(x: (size.width - shape.width) / 2, y: size.height - shape.height,
                                  width: shape.width, height: shape.height)
        root.addSubview(silhouette)
        card.view.frame = root.bounds
        root.addSubview(card.view)
        return root
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
