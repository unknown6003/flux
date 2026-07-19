import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// EXPERIMENTAL — default OFF, behind a settings key the wiring agent gates
/// this through `setEnabled(_:)` (e.g. `flux.notch.lockScreenExperiment`;
/// this class has no opinion of its own about the default or the key name).
///
/// Keeps a minimal, non-interactive notch silhouette visible on the macOS
/// lock screen — purely a "the Mac is still here, still running" ambient
/// presence, optionally captioned with a line from whatever the notch's
/// current activity is (e.g. a running timer's countdown), via an injected
/// closure rather than a live dependency on any concrete widget/service.
///
/// ## Why this is fragile by construction, and why that's the acceptable cost
/// This mechanism rides on things Apple has never documented and could change
/// or refuse outright in any macOS release:
///   1. `"com.apple.screenIsLocked"`/`"com.apple.screenIsUnlocked"` on
///      `DistributedNotificationCenter` — undocumented but long-established;
///      screen savers and various lock-screen-aware utilities have relied on
///      these exact names for years (the same "undocumented but
///      long-established, treat as a nudge to re-check, never trust the
///      payload" posture `PermissionCenter.observeAccessibilityChanges`
///      already takes with `"com.apple.accessibility.api"`).
///   2. `CGShieldingWindowLevel()` — the window level the lock screen's own
///      shield sits at. Drawing one level above it is what makes anything
///      visible over the shield at all, but that level is a private,
///      unstable implementation detail of the lock screen, not a public API
///      contract — see `shieldedLevel`'s own doc comment for the defensive
///      fallback this leans on if it ever stops making sense.
///   3. Drawing ANYTHING above the lock screen shield is exactly the kind of
///      trick a future macOS (or SIP) could simply refuse outright.
///
/// None of that is something application code can fix — it can only fail
/// safely. That's the whole design brief for this type:
///   - defaults OFF, entirely the wiring agent's call via `setEnabled(_:)`;
///   - never force-unwraps anything anywhere on the lock path;
///   - never crashes if the notification never fires, if the computed window
///     level is nonsensical, or if the panel simply fails to show — the
///     worst acceptable outcome is always "the silhouette doesn't appear,"
///     never a hang or anything that could interfere with the user actually
///     unlocking their own Mac (see `makePanel`'s `ignoresMouseEvents`).
@MainActor
final class LockScreenPresenter {
    /// Supplies the caption line shown under the silhouette. The wiring
    /// agent is expected to wire this generically to whatever the notch's
    /// CURRENT live activity is — `notchWindow.activities.current?.captionText`
    /// — falling back to `TimersWidget.nearestRemainingLine(at:)` only when
    /// nothing else is currently showing, rather than hardcoding this to
    /// timers specifically (`nil` from both means there's nothing worth
    /// captioning, which renders no caption at all). Read fresh every time a
    /// panel is built on lock, not cached at `init` or at `setEnabled` time —
    /// a lock that happens long after launch should caption whatever's
    /// current at THAT moment.
    var currentActivityLine: (() -> String?)?

    private var isEnabled = false
    private var isObserving = false
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    /// True only while an actual panel is up and showing on the lock screen —
    /// `false` at every other time, including "enabled but not locked" and
    /// "locked but disabled, or no built-in notched screen to hug". Exposed
    /// (read-only) purely for `--selftest`/debug so the on/off transitions
    /// can be asserted without a real lock session.
    private(set) var isPresentingOnLockScreen = false

    init() {}

    deinit {
        // `Task`-free, observer-free teardown: `AnyCancellable`'s own
        // deinit cancels each Combine subscription when this set is
        // released, and `NSPanel.orderOut`/dropping `panel` needs no
        // explicit call here — neither depends on `self` surviving past
        // this point.
    }

    /// The single on/off gate — mirrors every other notch-suite `setEnabled`
    /// (`NotchWindowController.setEnabled`, `NotchWidgetRegistry.setEnabled`,
    /// `MediaKeyInterceptor`'s start/stop shape): turning this off tears
    /// EVERYTHING down — the `DistributedNotificationCenter` observers AND
    /// any panel currently showing — so a disabled experiment costs nothing
    /// at idle: no observer, no window, nothing left that could misfire.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            startObserving()
        } else {
            stopObserving()
            dismissPanel()
        }
    }

    // MARK: - Lock/unlock observation

    /// No-op if already observing — safe to call freely.
    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let center = DistributedNotificationCenter.default()
        center.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.handleLocked() }
            .store(in: &cancellables)
        center.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in self?.handleUnlocked() }
            .store(in: &cancellables)
    }

    /// No-op if not observing. Cancels both subscriptions above by dropping
    /// them — `AnyCancellable.cancel()` runs on deinit, which `removeAll()`
    /// triggers immediately since nothing else retains them.
    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        cancellables.removeAll()
    }

    /// A lock notification arrived. Guarded on `isEnabled` again here
    /// (belt-and-suspenders — `setEnabled(false)` already tears the
    /// observers down first, so this should be unreachable while disabled,
    /// but costs nothing to double-check on a path this defensive) and on
    /// there actually being a built-in notched screen to hug — an
    /// external-only clamshell setup, or a non-notch Mac, has nothing for
    /// this silhouette to sit over, so this does nothing at all rather than
    /// drawing an arbitrary rectangle somewhere on an external display.
    ///
    /// If a panel is ALREADY up (a second `"com.apple.screenIsLocked"`
    /// arrives with no intervening unlock — this notification's own delivery
    /// isn't documented as strictly one-shot per lock, and screen-lock/wake
    /// races are exactly the kind of thing that can double-fire it), this
    /// refreshes that existing panel's caption/position in place rather than
    /// building a brand new one: `showPanel` unconditionally overwrites
    /// `panel` with a fresh `NSPanel`, and dropping the old Swift reference
    /// does NOT order the old window out — it simply orphans it, still
    /// showing, above the lock screen shield, with nothing left able to
    /// dismiss it on the next unlock (`dismissPanel()` only ever knows about
    /// the CURRENT `panel`).
    private func handleLocked() {
        guard isEnabled else { return }
        guard let screen = NSScreen.builtInNotchedScreen, let notchRect = screen.notchRect else { return }
        if let panel {
            refreshPanel(panel, on: screen, notchRect: notchRect)
        } else {
            showPanel(on: screen, notchRect: notchRect)
        }
    }

    private func handleUnlocked() {
        dismissPanel()
    }

    // MARK: - Panel

    private func showPanel(on screen: NSScreen, notchRect: NSRect) {
        let panel = makePanel(notchSize: notchRect.size)
        self.panel = panel
        position(panel, on: screen, notchRect: notchRect)
        panel.orderFrontRegardless()
        isPresentingOnLockScreen = true
    }

    /// Updates an already-showing panel's caption and position in place
    /// instead of building a new one — the `handleLocked()` re-entry path.
    /// Rebuilds just the SwiftUI root (cheap — a static silhouette plus a
    /// `Text`) via the existing `NSHostingView`, so the underlying `NSPanel`
    /// itself, and this presenter's `panel` reference to it, never change.
    private func refreshPanel(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let capturedLine = currentActivityLine?()
        if let hosting = panel.contentView as? NSHostingView<LockScreenSilhouetteView> {
            hosting.rootView = LockScreenSilhouetteView(notchSize: notchRect.size, caption: capturedLine)
        }
        position(panel, on: screen, notchRect: notchRect)
        panel.orderFrontRegardless()
        isPresentingOnLockScreen = true
    }

    /// Orders out and releases the panel — matches `NotchWindowController.
    /// setEnabled(false)`'s "tear down completely, don't just hide" shape for
    /// the same reason: nothing about this feature should linger once it's
    /// no longer meant to be shown. Safe to call whether or not a panel
    /// currently exists.
    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        isPresentingOnLockScreen = false
    }

    /// Builds the lock-screen panel: the `NotchHighlightWindow` recipe
    /// (borderless, nonactivating, clear, `.canJoinAllSpaces`/
    /// `.fullScreenAuxiliary`/`.stationary` — see that type's own doc
    /// comment) but at `shieldedLevel` instead of `.statusBar`, and — this is
    /// the safety-critical line — `ignoresMouseEvents = true`. The lock
    /// screen's own password field/UI sits at (or below) the shield level
    /// this panel draws just above; without `ignoresMouseEvents`, a
    /// borderless-but-still-hit-testable panel spanning that space could
    /// intercept clicks/keystrokes meant for actually unlocking the Mac. This
    /// view has no interactive content at all (see `LockScreenSilhouetteView`'s
    /// own doc comment), so there is nothing lost by making that explicit and
    /// unconditional here.
    private func makePanel(notchSize: CGSize) -> NSPanel {
        let capturedLine = currentActivityLine?()
        let root = LockScreenSilhouetteView(notchSize: notchSize, caption: capturedLine)
        let hosting = NSHostingView(rootView: root)

        let panel = LockScreenPanel(contentRect: .zero,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        // Shared with `NotchPanel`/`NotchHighlightWindowController` — see
        // `OverlayPanel`'s own doc comment for the recipe this applies.
        OverlayPanel.applyOverlayStyle(to: panel, level: Self.shieldedLevel, ignoresMouseEvents: true)
        panel.contentView = hosting
        return panel
    }

    /// One level above the lock screen's own shield. `CGShieldingWindowLevel()`
    /// is a private, undocumented implementation detail (see the type doc
    /// comment's point 2) — this defensively falls back to `.statusBar`
    /// (still above ordinary app windows, just not guaranteed above the
    /// shield) if it ever returns a non-positive value, rather than
    /// constructing a nonsensical or wildly-off window level from it.
    private static var shieldedLevel: NSWindow.Level {
        let raw = CGShieldingWindowLevel()
        guard raw > 0 else { return .statusBar }
        return NSWindow.Level(rawValue: Int(raw) + 1)
    }

    /// Centers the panel on the notch, top-anchored, with a little extra
    /// height below for the optional caption — mirrors
    /// `NotchWindowController.position`/`NotchHighlightWindowController.
    /// position`'s identical centering math.
    private func position(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let width = max(notchRect.width, 140)
        let height = notchRect.height + 28
        let origin = NSPoint(x: notchRect.midX - width / 2, y: screen.frame.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}

/// An `NSPanel` subclass that can never become key or main — defense in
/// depth alongside `nonactivatingPanel`/`becomesKeyOnlyIfNeeded`/
/// `ignoresMouseEvents` in `LockScreenPresenter.makePanel`, the same
/// belt-and-suspenders `NotchPanel.canBecomeKey` already applies to the
/// ordinary notch panel. On a window sitting above the lock screen's own
/// shield, "never takes focus, never fires the lock screen's own hand-off
/// logic" is a safety property worth stacking redundant guarantees on, not
/// just relying on style-mask flags for.
private final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The static (no ticking, no animation, no interaction, no tracking areas)
/// silhouette: the black `NotchShape` at the physical notch's own size, plus
/// — if `caption` is non-`nil`/non-empty — a small caption line hung just
/// below it. `caption` is captured once per build of this view — at initial
/// panel-build time (`LockScreenPresenter.makePanel`) or, if a lock
/// notification fires again while a panel is already up, at that later
/// refresh (`LockScreenPresenter.refreshPanel`) — never re-read on a timer of
/// its own. The lock screen is a display-only surface with no controller left
/// running to react to anything between those builds, so this deliberately
/// shows a snapshot of "what was current the instant this view was last
/// (re)built" rather than continuing to update on its own. There is no
/// `@State`, `@ObservedObject`, tap gesture, or tracking area anywhere in
/// this view — it renders once per build and then just sits there.
private struct LockScreenSilhouetteView: View {
    let notchSize: CGSize
    let caption: String?

    var body: some View {
        VStack(spacing: 4) {
            NotchShape.collapsed
                .fill(Color.black)
                .frame(width: max(notchSize.width, 1), height: max(notchSize.height, 8))
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
