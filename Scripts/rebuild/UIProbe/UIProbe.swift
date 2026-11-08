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
            for width in [680, 840] {
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
                        return AboutPreferencesController(state: .init(version: "UI fixture", build: "fixture",
                            crashNotice: .previousSessionUnclean(cameraWasRunning: false)), onAction: { _ in })
                    }
                    return GeneralPreferencesController(state: .init(
                        launchAtLoginRequested: false, loginStatus: .disabled, hotkeysEnabled: true,
                        revealShortcut: .init(keyCode: 3, carbonModifiers: 6400),
                        notchShortcut: .init(keyCode: 45, carbonModifiers: 6400),
                        appearance: .system, automaticUpdateChecks: true,
                        permissions: PermissionKind.allCases.map { .init(kind: $0, status: $0 == .accessibility ? .allowed : .notAsked) }), onAction: { _ in })
                }
                guard let window = settings.window, let root = window.contentView else { throw ProbeError.noView }
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: width, height: 900))
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                var renderingError: (any Error)?
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    do { try render(root, to: output.appendingPathComponent("\(page.rawValue)-\(theme)-\(width).png")) }
                    catch { renderingError = error }
                }
                if let renderingError { throw renderingError }
                for scroll in descendants(root).compactMap({ $0 as? NSScrollView }) {
                    guard let document = scroll.documentView,
                          document.frame.height > scroll.contentView.bounds.height + 1 else { continue }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    root.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        do { try render(root, to: output.appendingPathComponent("\(page.rawValue)-\(theme)-\(width)-bottom.png")) }
                        catch { renderingError = error }
                    }
                    if let renderingError { throw renderingError }
                }
                settings.close()
            }
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
