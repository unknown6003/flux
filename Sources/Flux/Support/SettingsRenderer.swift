import SwiftUI
import AppKit

/// Renders the real `SettingsView` to a PNG off-screen via `ImageRenderer`.
/// Used by the `--render-settings <path> [light|dark]` launch flag so the exact
/// production UI can be captured deterministically, without a window, focus, or
/// Screen Recording permission. This is the same view the app shows at runtime.
@MainActor
enum SettingsRenderer {
    static func render(to path: String, appearanceName: String, tab: SettingsTab = .general) {
        // SwiftUI needs an app + appearance context for fonts/colors.
        _ = NSApplication.shared
        let isDark = appearanceName == "dark"
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance

        let view = SettingsView(initialTab: tab)
            .environmentObject(SettingsStore())
            .environmentObject(MenuBarArranger())
            .environmentObject(UpdateChecker())
            .environmentObject(NowPlayingService())
            .environmentObject(PermissionCenter())
            .environment(\.colorScheme, isDark ? .dark : .light)

        // Resolve system colors (controlBackgroundColor, etc.) against the
        // requested appearance by making it current during rendering.
        var nsImage: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0
            nsImage = renderer.nsImage
        }

        guard let nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
    }
}
