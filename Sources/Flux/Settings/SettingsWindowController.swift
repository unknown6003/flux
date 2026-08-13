import AppKit
import SwiftUI

/// Hosts the SwiftUI settings UI in a single, compact, non-resizable window.
/// Lazily created and reused so reopening is instant and cheap.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let updater: UpdateChecker
    private let nowPlaying: NowPlayingService
    private let permissions: PermissionCenter
    private let crashReporter: CrashReporter
    private var window: NSWindow?

    /// Fires with the new visibility whenever the window is shown or closed.
    /// Lets the app suppress the floating arrange hint while Settings — which
    /// already spells out the same guidance — is on screen.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// The tab currently showing. Tracked here (not just inside SwiftUI)
    /// so a programmatic route to a page can rebuild the detail content while
    /// preserving the stable window frame.
    private var currentTab: SettingsTab = .general

    init(settings: SettingsStore, arranger: MenuBarArranger, updater: UpdateChecker,
         nowPlaying: NowPlayingService, permissions: PermissionCenter,
         crashReporter: CrashReporter) {
        self.settings = settings
        self.arranger = arranger
        self.updater = updater
        self.nowPlaying = nowPlaying
        self.permissions = permissions
        self.crashReporter = crashReporter
        super.init()
    }

    /// The settings surface is one fixed sidebar/detail canvas. A tab switch
    /// changes only the scrollable detail content, never the window frame.
    private static let windowStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    private static let preferredContentSize = NSSize(width: SettingsLayout.contentWidth,
                                                     height: SettingsLayout.contentHeight)

    func show() {
        // A failure or a since-deleted download from an earlier session isn't
        // news; clearing it here means the General tab's update card opens
        // showing what's true now rather than a stale verdict.
        updater.clearStaleOutcome()
        if window == nil {
            window = makeWindow()
            applyFixedContentSize(on: NSScreen.main, center: true)
        } else {
            applyFixedContentSize(on: window?.screen ?? NSScreen.main, center: false)
        }
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
    /// an already-open window rebuilds its content controller to select the
    /// requested page. The stable window frame is deliberately preserved.
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
        let hosting = NSHostingController(rootView: root)
        // We own the window's size (fixed + clamped to the screen below); the
        // SwiftUI ScrollView absorbs any overflow. Letting the hosting controller
        // auto-size the window would re-expand it to the full content height and
        // re-introduce the off-screen overflow this fixes.
        hosting.sizingOptions = []
        return hosting
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeContentController())
        window.title = "Flux Settings"
        window.styleMask = Self.windowStyleMask
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        return window
    }

    // MARK: Sizing

    /// The detail pane scrolls when a section grows. The window itself stays
    /// at a comfortable native-preferences size, with only a small clamp for
    /// unusually short displays.

    /// Usable content height on `screen`. The visible frame excludes the menu
    /// bar and Dock, but includes room occupied by the window's titlebar, so
    /// account for that chrome before applying the edge margin.
    private func availableHeight(on screen: NSScreen?) -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let titlebarHeight = NSWindow.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 1, height: 0),
            styleMask: Self.windowStyleMask
        ).height
        return max(1, visible - titlebarHeight - 24)
    }

    private func fixedContentSize(on screen: NSScreen?) -> NSSize {
        let available = availableHeight(on: screen)
        let height: CGFloat
        if available >= 320 {
            height = max(320, min(Self.preferredContentSize.height, available))
        } else {
            // A very short display gets the largest content area it can
            // actually show; forcing the nominal minimum would put the title
            // bar or bottom rows off-screen again.
            height = available
        }
        return NSSize(width: Self.preferredContentSize.width, height: height)
    }

    /// Applies the one fixed preferences size for the current display.
    /// `contentMinSize` and `contentMaxSize` are pinned to the same value, so
    /// neither a tab switch nor an accidental drag can change it. Reapplying
    /// this on every show also restores the preferred height after the window
    /// was previously clamped on a short display.
    private func applyFixedContentSize(on screen: NSScreen?, center: Bool) {
        guard let window else { return }
        let size = fixedContentSize(on: screen)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        if center {
            window.center()
        } else if let screen {
            let constrained = window.constrainFrameRect(window.frame, to: screen)
            if constrained != window.frame {
                window.setFrame(constrained, display: false)
            }
        }
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
