import AppKit
import SwiftUI
import Combine

/// Hosts the SwiftUI settings UI in the same material/sidebar window shape as
/// Alcove. The detail pane scrolls internally, so changing sections never
/// changes the window's footprint or leaves a tall blank canvas behind.
/// Lazily created and reused so reopening is instant and cheap.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let updater: UpdateChecker
    private let nowPlaying: NowPlayingService
    private let permissions: PermissionCenter
    private let crashReporter: CrashReporter
    private let clipboardMonitor: ClipboardMonitor
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// Fires with the new visibility whenever the window is shown or closed.
    /// Lets the app suppress the floating arrange hint while Settings — which
    /// already spells out the same guidance — is on screen.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// The tab currently showing. Tracked here so menu-bar and notch menu
    /// entry points can open the requested sidebar section.
    private var currentTab: SettingsTab = .general

    init(settings: SettingsStore, arranger: MenuBarArranger, updater: UpdateChecker,
         nowPlaying: NowPlayingService, permissions: PermissionCenter,
         crashReporter: CrashReporter, clipboardMonitor: ClipboardMonitor) {
        self.settings = settings
        self.arranger = arranger
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
        // A failure or a since-deleted download from an earlier session isn't
        // news; clearing it here means the General tab's update card opens
        // showing what's true now rather than a stale verdict.
        updater.clearStaleOutcome()
        if window == nil {
            window = makeWindow()
            sizeToDesignSize()
        } else {
            clampSizeToScreen()
        }
        applyAppearance(settings.appearance)
        // Become a regular app for as long as Settings is open — see
        // `applyRegularActivationPolicy`.
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

    /// Back to a Dock-less accessory once nothing needs a window presence.
    static func applyAccessoryActivationPolicy() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opens Settings on a specific tab — the notch's right-click menu jumps
    /// straight to Notch rather than dropping the user on General to find it
    /// themselves.
    ///
    /// `SettingsView` seeds its own `@State` selection from `initialTab`, so
    /// an already-open window can't just be told to switch: its content
    /// controller is rebuilt (cheap — the whole view is a few cards over
    /// shared `EnvironmentObject`s) and re-fitted to the new tab's natural
    /// height, exactly as a manual tab switch would.
    func show(tab: SettingsTab) {
        if currentTab != tab {
            currentTab = tab
            if let window {
                window.contentViewController = makeContentController()
            }
        }
        show()
    }

    private func makeContentController() -> NSViewController {
        // Only records which tab is showing — deliberately does NOT resize.
        let root = SettingsView(initialTab: currentTab, onTabChange: { [weak self] tab in
            self?.currentTab = tab
        })
        .environmentObject(settings)
        .environmentObject(arranger)
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

    // MARK: Sizing

    /// The content view owns the full design footprint. All variation between
    /// sections is handled by the detail ScrollView, which keeps traffic
    /// lights, sidebar rows, and controls in stable positions.
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
        // Deferred a runloop turn: dropping to `.accessory` synchronously
        // from inside `windowWillClose` pulls the Dock tile and menu bar out
        // from under a window AppKit is still in the middle of closing.
        DispatchQueue.main.async { [weak self] in
            // Conditional: if anything re-opened Settings inside the same
            // runloop turn, demoting would leave an open window with no Dock
            // tile and no ⌘-Tab entry — the bug this whole change removes.
            guard self?.window?.isVisible != true else { return }
            Self.applyAccessoryActivationPolicy()
        }
    }
}
