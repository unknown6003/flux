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
            for page in [SettingsPage.general, .menuBar] {
                let settings = SettingsWindowController(initialPage: page) { page in
                    if page == .menuBar { return menuBarFixture() }
                    let controller = NSViewController()
                    let analytics = AnalyticsSettingsView()
                    let content = NSView()
                    analytics.translatesAutoresizingMaskIntoConstraints = false
                    content.addSubview(analytics)
                    NSLayoutConstraint.activate([
                        analytics.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                        analytics.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                        analytics.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
                    ])
                    controller.view = content
                    return controller
                }
                guard let window = settings.window, let root = window.contentView else { throw ProbeError.noView }
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: 840, height: 640))
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                var renderingError: (any Error)?
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    do { try render(root, to: output.appendingPathComponent("\(page.rawValue)-\(theme).png")) }
                    catch { renderingError = error }
                }
                if let renderingError { throw renderingError }
                settings.close()
            }
        }
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
            showRealIcons: {}, refresh: {}, openAccessibilitySettings: {}, checkAccessibility: {}, reviewIdentity: { _ in })
        return MenuBarPreferencesController(state: .init(mode: .perApplication, rows: rows), actions: actions)
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
