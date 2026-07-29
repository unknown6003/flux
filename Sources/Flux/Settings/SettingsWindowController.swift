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
    /// because switching tabs changes the content's natural height, and the
    /// window needs re-fitting the same way it does on first open.
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

    /// The settings content is a fixed 480pt wide; only its height varies, so the
    /// window resizes vertically only.
    private static let contentWidth: CGFloat = 480

    func show() {
        // A failure or a since-deleted download from an earlier session isn't
        // news; clearing it here means the General tab's update card opens
        // showing what's true now rather than a stale verdict.
        updater.clearStaleOutcome()
        if window == nil {
            window = makeWindow()
            sizeToFixedHeight()            // one height, measured once, held forever
        } else {
            clampHeightToScreen()          // re-fit in case the display changed since last time
        }
        // Become a regular app for as long as Settings is open — see
        // `applyRegularActivationPolicy`.
        Self.applyRegularActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
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
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        return window
    }

    // MARK: Sizing
    //
    // ## The window height is FIXED, and never changes again
    // It used to re-measure the active tab and grow/shrink to fit on every
    // switch. That made the window jump around under the pointer — the
    // Notch tab is far taller than About — moving the very controls you were
    // reaching for, and resizing a window out from under an open popover or
    // a mid-edit text field. Tabs are peers; a tab bar that resizes its own
    // container is the bug, not a feature.
    //
    // One height is measured once, from the TALLEST tab, and then held for
    // the window's whole life. Anything taller than that (a tab that grows
    // because a toggle revealed more rows) scrolls, which is what the
    // `ScrollView` in `SettingsView` was always there for.

    /// The measured fixed height, computed once on first open.
    private var fixedContentHeight: CGFloat?

    /// The natural height of one tab, measured from a non-scrolling copy.
    private func naturalContentHeight(of tab: SettingsTab) -> CGFloat {
        let probe = NSHostingView(rootView: SettingsView(scrolls: false, initialTab: tab)
            .environmentObject(settings)
            .environmentObject(arranger)
            .environmentObject(updater)
            .environmentObject(nowPlaying)
            .environmentObject(permissions)
            .environmentObject(crashReporter))
        probe.layoutSubtreeIfNeeded()
        return ceil(probe.fittingSize.height)
    }

    /// The tallest tab's natural height, clamped to the screen — measured
    /// once and cached, so no later content change can move the window.
    private func resolvedFixedHeight() -> CGFloat {
        if let fixedContentHeight { return fixedContentHeight }
        let tallest = SettingsTab.allCases.map { naturalContentHeight(of: $0) }.max() ?? 560
        let height = min(tallest, availableHeight(on: NSScreen.main))
        fixedContentHeight = height
        return height
    }

    /// Usable height for a window on `screen` — its visible frame already excludes
    /// the menu bar and Dock; a little breathing room keeps the title bar clear.
    private func availableHeight(on screen: NSScreen?) -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return max(320, visible - 24)
    }

    /// First-open sizing: the one fixed height, centred. `contentMinSize` and
    /// `contentMaxSize` are pinned to the same value, so neither a tab switch
    /// nor a user drag can change it — the window is genuinely fixed, not
    /// merely "sized correctly for now".
    private func sizeToFixedHeight() {
        guard let window else { return }
        let height = resolvedFixedHeight()
        let size = NSSize(width: Self.contentWidth, height: height)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.center()
    }

    /// Re-open sizing: only ever shrinks to fit a smaller screen (the window
    /// was moved to a laptop display since last time). Never grows, never
    /// re-measures content.
    private func clampHeightToScreen() {
        guard let window else { return }
        let available = availableHeight(on: window.screen)
        guard let current = window.contentView?.frame.height, current > available else { return }
        let size = NSSize(width: Self.contentWidth, height: available)
        fixedContentHeight = available
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
        // Deferred a runloop turn: dropping to `.accessory` synchronously
        // from inside `windowWillClose` pulls the Dock tile and menu bar out
        // from under a window AppKit is still in the middle of closing.
        DispatchQueue.main.async { Self.applyAccessoryActivationPolicy() }
    }
}
