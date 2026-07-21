import SwiftUI
import AppKit
import Foundation

/// Shared off-screen render-to-PNG pipeline behind both `--snapshot`
/// (`SettingsSnapshot`) and `--snapshot-notch` (`NotchSnapshot`): host
/// arbitrary, already environment-configured SwiftUI content in a real (but
/// never on-screen) window and capture it with `cacheDisplay(in:to:)`. Unlike
/// `ImageRenderer` (see `SettingsRenderer`, used for the separate
/// `--render-settings` flag), this draws through AppKit's own path, so
/// genuine `NSSwitch`/`NSSlider`/`NSSegmentedControl` chrome appears exactly
/// as it does at runtime. No Screen Recording permission required, since
/// nothing is ever actually placed on a visible display.
@MainActor
enum OffscreenRender {
    /// - Parameters:
    ///   - rootView: the SwiftUI content to render, already wrapped in
    ///     whatever `environmentObject`/`environment` values it needs.
    ///   - size: the fixed frame to render at.
    ///   - dark: applies `.darkAqua`/`.aqua` to the hosting view and window.
    ///   - opaque: whether the off-screen window itself is opaque (Settings —
    ///     a real window's chrome) or transparent (the notch panel, which
    ///     draws its own shape over nothing and needs a clear backdrop).
    ///   - settleDelay: how long to let SwiftUI finish layout and an initial
    ///     draw pass before capturing — both current call sites use 0.8s.
    ///   - label: prefixes every stderr diagnostic (e.g. "snapshot" /
    ///     "snapshot-notch") so a CI failure log can tell which pipeline
    ///     failed without inspecting the path argument.
    ///   - path: destination PNG path.
    ///
    /// Always exits the process — success (`0`) once the PNG is written, or
    /// failure (`1`) if either AppKit capture step comes back empty — since
    /// every current single-shot CLI mode wants exactly that. `NotchSnapshot.
    /// captureAll` needs the same off-screen-window-and-bitmap recipe but
    /// *without* the `exit()` (it renders three PNGs in one process and exits
    /// itself, once, at the end) — see `render(rootView:size:dark:opaque:
    /// settleDelay:label:to:)` below, which is the actual recipe this
    /// function is now a thin, exiting wrapper around.
    static func capture(rootView: AnyView, size: CGSize, dark: Bool, opaque: Bool = true,
                        settleDelay: TimeInterval = 0.8, label: String, to path: String) {
        let success = render(rootView: rootView, size: size, dark: dark, opaque: opaque,
                             settleDelay: settleDelay, label: label, to: path)
        exit(success ? 0 : 1)
    }

    /// The actual off-screen NSWindow/NSHostingView/`cacheDisplay(in:to:)`
    /// recipe, factored out of `capture` (above) so a caller that needs to
    /// render more than one PNG in a single process — `NotchSnapshot.
    /// captureAll`, which renders collapsed/activity/expanded in one launch —
    /// can drive it directly without `capture`'s own unconditional `exit()`
    /// ending the process after the first one. Same parameters as `capture`,
    /// minus the terminal exit code; returns whether the PNG was written
    /// successfully instead.
    @discardableResult
    static func render(rootView: AnyView, size: CGSize, dark: Bool, opaque: Bool = true,
                       settleDelay: TimeInterval = 0.8, label: String, to path: String) -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)

        // An off-screen window gives the hierarchy a backing store to draw
        // into without ever appearing on the visible display.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = appearance
        if !opaque {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)

        // Let SwiftUI complete layout and an initial draw pass.
        RunLoop.current.run(until: Date().addingTimeInterval(settleDelay))
        hosting.layoutSubtreeIfNeeded()

        let rect = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else {
            FileHandle.standardError.write(Data("\(label): no bitmap rep\n".utf8))
            return false
        }
        rep.size = rect.size
        hosting.cacheDisplay(in: rect, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("\(label): png encode failed\n".utf8))
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("\(label): write failed: \(error)\n".utf8))
            return false
        }
        FileHandle.standardError.write(Data("\(label) wrote \(path) (\(Int(size.width))x\(Int(size.height)))\n".utf8))
        return true
    }
}
