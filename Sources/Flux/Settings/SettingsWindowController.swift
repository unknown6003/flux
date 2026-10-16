import AppKit
import SwiftUI
import Combine

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let iconManager: MenuBarIconManager
    private let updater: UpdateChecker
    private let nowPlaying: NowPlayingService
    private let permissions: PermissionCenter
    private let crashReporter: CrashReporter
    private let clipboardMonitor: ClipboardMonitor
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    var onVisibilityChanged: ((Bool) -> Void)?

    private let selection = SettingsSelection()

    init(settings: SettingsStore, arranger: MenuBarArranger, iconManager: MenuBarIconManager, updater: UpdateChecker,
         nowPlaying: NowPlayingService, permissions: PermissionCenter,
         crashReporter: CrashReporter, clipboardMonitor: ClipboardMonitor) {
        self.settings = settings
        self.arranger = arranger
        self.iconManager = iconManager
        self.updater = updater
        self.nowPlaying = nowPlaying
        self.permissions = permissions
        self.crashReporter = crashReporter
        self.clipboardMonitor = clipboardMonitor
        super.init()

        settings.$appearance
            .removeDuplicates()
            .sink { [weak self] appearance in
                self?.applyAppearance(appearance)
            }
            .store(in: &cancellables)
    }

    private static let contentSize = SettingsView.designSize

    func show() {
        let resumesIconManagement = selection.tab == .menuBar && window?.isVisible == false
        updater.clearStaleOutcome()
        if window == nil {
            window = makeWindow()
            sizeToDesignSize()
        } else {
            clampSizeToScreen()
        }
        applyAppearance(settings.appearance)
        Self.applyRegularActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        // `makeKeyAndOrderFront` does NOT restore a minimized window — that
        // lives in `NSWindowController.showWindow`, which this class doesn't
        // use. Without this, minimizing Settings was a one-way trip: every
        // route back (menu-bar item, notch right-click, Dock tile) would
        // activate the app and show nothing, `windowWillClose` would never
        // fire, and the app would sit permanently `.regular` with an unwanted
        // Dock icon and an apparently-missing window. Minimize only became
        // reachable at all when this commit's sibling added `.miniaturizable`
        // and a ⌘M item, so this arrived with it.
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if resumesIconManagement { iconManager.beginIconManagement() }
        onVisibilityChanged?(true)
    }

    /// Promotes Flux from `.accessory` to `.regular` while Settings is on
    /// screen, and back again when it closes.
    ///
    /// Flux is `LSUIElement` (see `Info.plist`) because a menu-bar utility
    /// has no business owning a permanent Dock icon. The cost is that its
    /// Settings window was invisible to every normal way of managing a
    /// window: no Dock tile, no ⌘-Tab entry, no Window menu, no Mission
    /// Control grouping. Open it, click away, and the only route back was the
    /// chevron — and there was no obvious way to close or reach it at all.
    ///
    /// Switching policy for the window's lifetime gets all of that for free
    /// and gives it up again the moment it closes, so the idle app is still
    /// Dock-less. `NSApp.activate` must come AFTER the switch, or the newly
    /// regular app is left behind whatever was frontmost.
    static func applyRegularActivationPolicy() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    static func applyAccessoryActivationPolicy() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func show(tab: SettingsTab) {
        if selection.tab != tab { selection.tab = tab }
        show()
    }

    private func makeContentController() -> NSViewController {
        let root = SettingsView(selection: selection)
        .environmentObject(settings)
        .environmentObject(arranger)
        .environmentObject(iconManager)
        .environmentObject(updater)
        .environmentObject(nowPlaying)
        .environmentObject(permissions)
        .environmentObject(crashReporter)
        .environmentObject(clipboardMonitor)
        let hosting = NSHostingController(rootView: root)
        // We own the window's size (measured + clamped to the screen below); the
        // SwiftUI ScrollView absorbs any overflow. Letting the hosting controller
        // auto-size the window would re-expand it to the full content height and
        // re-introduce the off-screen overflow this fixes.
        hosting.sizingOptions = []
        return hosting
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeContentController())
        window.title = "Flux Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.appearance = settings.appearance.nsAppearance
        return window
    }

    private func applyAppearance(_ appearance: FluxAppearance) {
        window?.appearance = appearance.nsAppearance
        window?.contentView?.appearance = appearance.nsAppearance
    }


    private func sizeToDesignSize() {
        guard let window else { return }
        let size = sizeThatFitsScreen(on: NSScreen.main)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.center()
    }

    private func sizeThatFitsScreen(on screen: NSScreen?) -> NSSize {
        let visibleHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(Self.contentSize.height, max(420, visibleHeight - 24))
        return NSSize(width: Self.contentSize.width, height: height)
    }

    private func clampSizeToScreen() {
        guard let window else { return }
        let size = sizeThatFitsScreen(on: window.screen)
        guard window.contentView?.frame.size != size else { return }
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
        iconManager.endIconManagement()
        // Deferred a runloop turn: dropping to `.accessory` synchronously
        // from inside `windowWillClose` pulls the Dock tile and menu bar out
        // from under a window AppKit is still in the middle of closing.
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible != true else { return }
            Self.applyAccessoryActivationPolicy()
        }
    }
}
