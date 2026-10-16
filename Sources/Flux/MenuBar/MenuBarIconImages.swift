import AppKit
import Combine
import ScreenCaptureKit

/// Reads only the menu bar band while the layout editor is open.
@MainActor
final class MenuBarIconImages: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var message: String?
    @Published private(set) var hasAccess = false
    private var job: Task<Void, Never>?
    private var generation = 0
    private var isOpen = false
    private var inventory: [MenuBarIconManager.Icon] = []

    func open(_ icons: [MenuBarIconManager.Icon]) {
        isOpen = true
        refresh(icons, force: true)
    }

    func requestAccess(_ icons: [MenuBarIconManager.Icon]) {
        _ = CGRequestScreenCaptureAccess()
        refresh(icons, force: true)
    }

    func refresh(_ icons: [MenuBarIconManager.Icon], force: Bool = false) {
        guard force || inventory != icons || (images.isEmpty && job == nil) else { return }
        generation += 1
        let token = generation
        job?.cancel()
        job = nil
        inventory = icons
        if !images.isEmpty { images = [:] }
        if isOpen {
            let granted = CGPreflightScreenCaptureAccess()
            if hasAccess != granted { hasAccess = granted }
        }
        guard isOpen, hasAccess, !icons.isEmpty else {
            if !images.isEmpty { images = [:] }
            return
        }
        let scales = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            screen.displayID.map { ($0, screen.backingScaleFactor) }
        })
        job = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var result: [String: NSImage] = [:]
                for display in content.displays {
                    try Task.checkCancellation()
                    let items = icons.filter { $0.frame.width > 0 && $0.frame.height > 0
                        && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                        && $0.frame.minY >= display.frame.minY && $0.frame.maxY <= display.frame.minY + 80 }
                    guard !items.isEmpty else { continue }
                    let scale = scales[display.displayID] ?? 1
                    let height = items.map { $0.frame.maxY - display.frame.minY }.max() ?? 24
                    let configuration = SCStreamConfiguration()
                    configuration.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
                    configuration.width = Int(ceil(display.frame.width * scale))
                    configuration.height = Int(ceil(height * scale))
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
                    try Task.checkCancellation()
                    for item in items {
                        let crop = CGRect(x: (item.frame.minX - display.frame.minX) * scale,
                                          y: (item.frame.minY - display.frame.minY) * scale,
                                          width: item.frame.width * scale, height: item.frame.height * scale).integral
                        if let glyph = image.cropping(to: crop) {
                            result[item.id] = NSImage(cgImage: glyph, size: item.frame.size)
                        }
                    }
                }
                guard let self, self.generation == token, self.isOpen else { return }
                self.images = result
                self.message = nil
                self.job = nil
            } catch {
                guard let self, self.generation == token, self.isOpen else { return }
                self.message = "Menu bar images are unavailable. App icons are shown."
                self.job = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == token, self.job != nil else { return }
            self.generation += 1
            self.job?.cancel()
            self.job = nil
            self.message = "Menu bar images are unavailable. App icons are shown."
        }
    }

    func close() {
        isOpen = false
        inventory = []
        generation += 1
        job?.cancel()
        job = nil
        if !images.isEmpty { images = [:] }
        message = nil
    }
}
