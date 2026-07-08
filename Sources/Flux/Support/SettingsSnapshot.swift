import SwiftUI
import AppKit

/// Captures the *real* settings UI — including genuine AppKit controls
/// (NSSwitch, NSSlider, NSSegmentedControl) — by hosting `SettingsView` in an
/// off-screen window and rendering it with `cacheDisplay(in:to:)`. Unlike
/// `ImageRenderer`, this uses AppKit's own draw path, so native controls appear
/// exactly as they do at runtime. No Screen Recording permission required.
///
///   Flux --snapshot <path> [light|dark]
@MainActor
enum SettingsSnapshot {
    static func capture(to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        app.appearance = appearance

        let store = SettingsStore()
        let root = SettingsView()
            .environmentObject(store)
            .environmentObject(MenuBarArranger())
            .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.appearance = appearance
        let fitting = hosting.fittingSize
        let size = NSSize(width: 480, height: max(fitting.height, 560))
        hosting.frame = NSRect(origin: .zero, size: size)

        // An off-screen window gives the hierarchy a backing store to draw into
        // without ever appearing on the visible display.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = appearance
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)

        // Let SwiftUI complete layout and an initial draw pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        let rect = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else {
            FileHandle.standardError.write(Data("snapshot: no bitmap rep\n".utf8))
            exit(1)
        }
        rep.size = rect.size
        hosting.cacheDisplay(in: rect, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: png encode failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot wrote \(path) (\(Int(size.width))x\(Int(size.height)))\n".utf8))
        exit(0)
    }
}
