import AppKit
import SwiftUI
import Combine

/// Owns the notch panel's entire lifecycle: creating the shared registry and
/// activity center, building the panel only when a built-in notched screen
/// exists, sizing/positioning it over the physical notch, and tearing it
/// down/rebuilding it whenever the display configuration changes (external
/// monitor connect/disconnect, clamshell close/open).
///
/// This is the one entry point the wiring agent needs: construct it, register
/// widgets on `.registry`, post activities via `.activities`, feed settings
/// into `.viewModel`'s public properties, and call `setEnabled` to match the
/// user's `flux.notch.enabled` preference.
@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    let registry: NotchWidgetRegistry
    let activities: LiveActivityCenter

    /// Supplies now-playing artwork for the activity wings — forwarded
    /// straight to `NotchRootView`. Set by the wiring agent once the Now
    /// Playing service exists; rebuilding the root view on every set is cheap
    /// (SwiftUI reuses the existing panel/window, it just re-renders).
    var artworkProvider: (() -> NSImage?)? {
        didSet { refreshRootView() }
    }

    /// Lets the wiring agent intercept a tap on a live activity's wings —
    /// forwarded straight to `NotchRootView.onActivityTap`. See that
    /// property's doc comment; set once by the wiring agent (e.g. to route
    /// `.menuBarOverflow` into Arrange Mode).
    var onActivityTap: ((LiveActivity.Kind) -> Bool)? {
        didSet { refreshRootView() }
    }

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView?
    private var isEnabled = false
    /// Mirrors `SettingsStore.notchShowInFullscreen`; applied to `panel` as
    /// soon as one exists, and re-applied to every panel `makePanel()` builds
    /// (a screen change tears down and rebuilds the panel, which would
    /// otherwise silently reset to the `NotchPanel.init` default).
    private var showInFullscreen = true
    private var cancellables = Set<AnyCancellable>()

    init() {
        let registry = NotchWidgetRegistry()
        let activities = LiveActivityCenter()
        self.registry = registry
        self.activities = activities
        self.viewModel = NotchViewModel(registry: registry, activities: activities)

        // The only thing that can change which screen (if any) is the
        // built-in notched one: a monitor connects/disconnects, or the lid
        // closes/opens over a clamshell setup. Both fire this notification.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.resolveScreen() }
            .store(in: &cancellables)
    }

    /// Turns the whole notch feature on/off. Disabling tears the panel down
    /// completely (not just orders it out), so a disabled notch costs
    /// nothing: no hidden window, no SwiftUI body still attached and ticking.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            resolveScreen()
        } else {
            // Force the state machine to `.collapsed` *before* tearing the
            // panel down. A plain `collapse()` could re-enter `.activity` if
            // one happened to be current, leaving an expanded widget's
            // `didDismiss()` never called even though its panel just
            // vanished — `forceCollapse()` guarantees the exactly-once
            // willPresent/didDismiss pairing holds even on the way out.
            viewModel.forceCollapse()
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
        }
    }

    /// Mirrors `SettingsStore.notchShowInFullscreen` into the live panel (and
    /// remembers it for the next panel `makePanel()` builds, e.g. after a
    /// screen change).
    func setShowInFullscreen(_ show: Bool) {
        showInFullscreen = show
        panel?.setShowInFullscreen(show)
    }

    // MARK: - Screen resolution

    /// Finds (or loses) the built-in notched screen and reflects that in the
    /// panel: create-and-show if one exists and there's no panel yet,
    /// reposition if one already exists, or order out (without discarding
    /// state) if none currently qualifies — e.g. a clamshell Mac running on
    /// an external-only setup. Ordering out rather than tearing down means
    /// returning to the built-in display (opening the lid) reattaches
    /// instantly, with the notch UI's state exactly as it was left.
    private func resolveScreen() {
        guard isEnabled else { return }
        guard let screen = NSScreen.builtInNotchedScreen, let notchRect = screen.notchRect else {
            panel?.orderOut(nil)
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        hostingView?.rootView = makeRootView(notchSize: notchRect.size)
        position(panel, on: screen, notchRect: notchRect)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(viewModel: viewModel)
        panel.setShowInFullscreen(showInFullscreen)
        let hosting = NotchHostingView(viewModel: viewModel, rootView: makeRootView(notchSize: .zero))
        panel.contentView = hosting
        hostingView = hosting
        return panel
    }

    private func makeRootView(notchSize: CGSize) -> AnyView {
        AnyView(NotchRootView(viewModel: viewModel, notchSize: notchSize,
                              artworkProvider: artworkProvider, onActivityTap: onActivityTap))
    }

    private func refreshRootView() {
        guard let hostingView, let notchSize = NSScreen.builtInNotchedScreen?.notchRect?.size else { return }
        hostingView.rootView = makeRootView(notchSize: notchSize)
    }

    /// Sizes the panel to the max-expanded bounds and centers it, top-anchored,
    /// on the physical notch. This frame never changes with `viewModel.state`
    /// — only the SwiftUI content inside grows/shrinks — so repositioning only
    /// has to happen when the screen itself changes.
    private func position(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let width = NotchMetrics.expandedWidth(for: notchRect.width)
        let height = NotchMetrics.expandedHeight
        let origin = NSPoint(x: notchRect.midX - width / 2, y: screen.frame.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
