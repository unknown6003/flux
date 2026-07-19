import AppKit

/// The shared recipe behind every borderless, non-activating overlay panel
/// this app draws above ordinary app windows — `NotchPanel` (the notch
/// itself), `NotchHighlightWindowController`'s menu-bar overflow glow, and
/// `LockScreenPresenter`'s lock-screen silhouette all independently arrived
/// at the identical set of `NSPanel` property assignments below before this
/// was pulled out into one place:
///   - `.borderless`/`.nonactivatingPanel` (set by each site's own
///     `super.init`/`init` — this type doesn't own that part, since two of
///     the three sites are `NSPanel` subclasses that must call it themselves)
///     plus `isFloatingPanel`/`becomesKeyOnlyIfNeeded` so the panel never
///     takes key window or steals focus from whatever app the user is in;
///   - `hidesOnDeactivate = false`, `isOpaque = false`/`backgroundColor =
///     .clear`/`hasShadow = false` so nothing but each site's own SwiftUI
///     content is ever visible, and it stays up even while Flux itself isn't
///     the active app;
///   - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
///     .stationary]` so it rides above normal windows and survives Space
///     switches and fullscreen apps;
///   - a caller-supplied `level` (each site sits at a different one —
///     `.statusBar` for the two menu-bar-adjacent overlays,
///     `LockScreenPresenter`'s own shield-plus-one for the lock screen) and
///     `ignoresMouseEvents` (each site's own answer to whether it has any
///     interactive content worth hit-testing at all).
enum OverlayPanel {
    /// Builds a plain, ready-to-position `NSPanel` with the shared recipe
    /// applied — for call sites that don't need a dedicated `NSPanel`
    /// subclass of their own. `NotchPanel` and `LockScreenPresenter`'s own
    /// `LockScreenPanel` both need to BE their own subclass (for
    /// `canBecomeKey`/swipe recognition/drag-and-drop, and for
    /// `canBecomeKey`/`canBecomeMain` respectively), so they can't receive an
    /// already-built plain `NSPanel` from here — they call `applyOverlayStyle`
    /// below on themselves instead, right after their own `super.init`.
    static func make(level: NSWindow.Level, ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        applyOverlayStyle(to: panel, level: level, ignoresMouseEvents: ignoresMouseEvents)
        return panel
    }

    /// The shared styling itself, factored out so a subclass that must call
    /// `super.init(...)` directly (rather than receiving an already-built
    /// panel from `make(level:ignoresMouseEvents:)`) can still apply the
    /// exact same assignments to itself afterward.
    static func applyOverlayStyle(to panel: NSPanel, level: NSWindow.Level, ignoresMouseEvents: Bool) {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = ignoresMouseEvents
    }
}
