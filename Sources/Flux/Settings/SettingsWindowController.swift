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
    private var window: NSWindow?

    /// Fires with the new visibility whenever the window is shown or closed.
    /// Lets the app suppress the floating arrange hint while Settings — which
    /// already spells out the same guidance — is on screen.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// The tab currently showing. Tracked here (not just inside SwiftUI)
    /// because switching tabs changes the content's natural height, and the
    /// window needs re-fitting the same way it does on first open.
    private var currentTab: SettingsTab = .general

    init(settings: SettingsStore, arranger: MenuBarArranger, updater: UpdateChecker, nowPlaying: NowPlayingService) {
        self.settings = settings
        self.arranger = arranger
        self.updater = updater
        self.nowPlaying = nowPlaying
        super.init()
    }

    /// The settings content is a fixed 480pt wide; only its height varies, so the
    /// window resizes vertically only.
    private static let contentWidth: CGFloat = 480

    func show() {
        if window == nil {
            window = makeWindow()
            sizeToNaturalHeight()          // first open: fit content, clamp to screen, center
        } else {
            clampHeightToScreen()          // re-fit in case the display changed since last time
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(initialTab: currentTab, onTabChange: { [weak self] tab in
            self?.currentTab = tab
            self?.refitForTabChange()
        })
        .environmentObject(settings)
        .environmentObject(arranger)
        .environmentObject(updater)
        .environmentObject(nowPlaying)
        let hosting = NSHostingController(rootView: root)
        // We own the window's size (measured + clamped to the screen below); the
        // SwiftUI ScrollView absorbs any overflow. Letting the hosting controller
        // auto-size the window would re-expand it to the full content height and
        // re-introduce the off-screen overflow this fixes.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Flux Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
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

    /// The height `currentTab`'s content wants when nothing is scrolled. Measured
    /// from a non-scrolling copy of just that tab so a tall update banner or extra
    /// rows are accounted for.
    private func naturalContentHeight() -> CGFloat {
        let probe = NSHostingView(rootView: SettingsView(scrolls: false, initialTab: currentTab)
            .environmentObject(settings)
            .environmentObject(arranger)
            .environmentObject(updater)
            .environmentObject(nowPlaying))
        probe.layoutSubtreeIfNeeded()
        return ceil(probe.fittingSize.height)
    }

    /// Usable height for a window on `screen` — its visible frame already excludes
    /// the menu bar and Dock; a little breathing room keeps the title bar clear.
    private func availableHeight(on screen: NSScreen?) -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return max(320, visible - 24)
    }

    /// First-open sizing: open at the content's natural height, but never taller
    /// than the screen (then the ScrollView takes over), and centre the window.
    private func sizeToNaturalHeight() {
        guard let window else { return }
        let natural = naturalContentHeight()
        let available = availableHeight(on: NSScreen.main)
        let width = Self.contentWidth
        window.contentMinSize = NSSize(width: width, height: min(320, natural))
        window.contentMaxSize = NSSize(width: width, height: natural)   // no point being taller than the content
        window.setContentSize(NSSize(width: width, height: min(natural, available)))
        window.center()
    }

    /// Re-open sizing: keep the user's size/position, but shrink to fit if the
    /// window is now taller than the screen it's on (e.g. moved to a laptop display).
    private func clampHeightToScreen() {
        guard let window else { return }
        let natural = naturalContentHeight()
        let available = availableHeight(on: window.screen)
        // Set alongside `contentMaxSize`, and always before `setContentSize`
        // below: `min(320, natural)` can never exceed `natural` itself, so
        // min ≤ max holds no matter how tall (or short) this tab's content
        // is — leaving `contentMinSize` at a stale, taller value from a
        // previous (taller) tab could otherwise pin the window above the max
        // this tab just set, or reject `setContentSize` outright.
        window.contentMinSize = NSSize(width: Self.contentWidth, height: min(320, natural))
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: natural)
        if let contentHeight = window.contentView?.frame.height, contentHeight > available {
            window.setContentSize(NSSize(width: Self.contentWidth, height: available))
        }
    }

    /// Switching tabs changes the content's natural height (e.g. the Menu Bar
    /// tab's live preview + Arrange Mode card is taller than About) — re-measure
    /// and grow/shrink the window to fit the new tab, same clamp-to-screen rule
    /// as the initial open.
    private func refitForTabChange() {
        guard let window else { return }
        let natural = naturalContentHeight()
        let available = availableHeight(on: window.screen)
        // See `clampHeightToScreen`'s comment on this same pairing — a tab
        // switch is exactly the case that comment worries about: min/max both
        // need to reflect the *new* tab's natural height before
        // `setContentSize` runs, or a leftover min from a taller previous tab
        // can end up above this tab's own max.
        window.contentMinSize = NSSize(width: Self.contentWidth, height: min(320, natural))
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: natural)
        window.setContentSize(NSSize(width: Self.contentWidth, height: min(natural, available)))
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
    }
}
