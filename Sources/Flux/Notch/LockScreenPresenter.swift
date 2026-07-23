import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// EXPERIMENTAL — default OFF, gated by `flux.notch.lockScreenExperiment`
/// (the wiring agent's `setEnabled(_:)` call, in `AppDelegate.
/// configureLockScreenPresenter()` — this class has no opinion of its own
/// about the default or the key name, and that master flag remains the ONE
/// gate: every sub-feature below (`LockScreenContentView`'s Now Playing
/// pill/activity pill/unlock pill, plus the unlock sound) only ever runs
/// while this is enabled).
///
/// M9 (Alcove lock-screen parity): keeps a LIVE `LockScreenContentView` —
/// the notch silhouette plus up to three stacked pills (Now Playing, the
/// current live activity's caption, an optional "Press any key to unlock"
/// pill) — visible on the macOS lock screen, purely display-only, between
/// `screenIsLocked`/`screenIsUnlocked` distributed notifications. Replaces
/// the M6 static silhouette+caption (a plain `Text` captured once per panel
/// build via an injected `currentActivityLine` closure): this class now
/// holds direct, read-only references to `NowPlayingService`/
/// `LiveActivityCenter`/`SettingsStore` instead, and the hosted SwiftUI view
/// observes the first two directly (`@ObservedObject`) so it re-renders on
/// its own as their state changes — no refresh-on-next-lock-notification
/// workaround needed the way the old `refreshPanel` rebuilt a static struct.
///
/// ## Why this is fragile by construction, and why that's the acceptable cost
/// This mechanism rides on things Apple has never documented and could change
/// or refuse outright in any macOS release:
///   1. `"com.apple.screenIsLocked"`/`"com.apple.screenIsUnlocked"` on
///      `DistributedNotificationCenter` — undocumented but long-established;
///      screen savers and various lock-screen-aware utilities have relied on
///      these exact names for years (treat as a nudge to re-check, never
///      trust the payload — the same posture every undocumented
///      `DistributedNotificationCenter` name in this codebase takes).
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
///     worst acceptable outcome is always "nothing extra appears," never a
///     hang or anything that could interfere with the user actually
///     unlocking their own Mac (see `makePanel`'s `ignoresMouseEvents`).
@MainActor
final class LockScreenPresenter {
    private let nowPlaying: NowPlayingService
    private let activities: LiveActivityCenter
    private let settings: SettingsStore

    private var isEnabled = false
    private var isObserving = false
    private var panel: NSPanel?
    private var hostingView: NSHostingView<LockScreenContentView>?
    private var currentNotchSize: CGSize = .zero
    private var cancellables = Set<AnyCancellable>()

    /// The pending "finish fading out, THEN order the panel out" deadline —
    /// see `fadeOutThenDismiss`'s own doc comment. The same cancellable
    /// single-deadline `DeadlineTask` helper `LiveActivityCenter`'s expiry
    /// tasks, `NotchActivityRouter`'s boundary tasks, and `TimerService`'s
    /// own deadline all already share — no repeating timer/Task anywhere in
    /// this pipeline either. Cancelled unconditionally at the top of every
    /// `handleLocked()`/`setEnabled(false)` path so a rapid lock→unlock→lock
    /// (or repeated unlock) cycle can never have a stale, already-superseded
    /// fade tear down a panel a newer lock just decided should stay up.
    private let fadeOutDeadline = DeadlineTask()

    /// True only while an actual panel is up and showing on the lock screen —
    /// `false` at every other time, including "enabled but not locked" and
    /// "locked but disabled, or no built-in notched screen to hug". Stays
    /// `true` through a fade-OUT in progress (the panel is still visibly
    /// there, just becoming transparent) and only flips `false` once the
    /// panel is actually ordered out. Exposed (read-only) purely for
    /// `--selftest`/debug so the on/off transitions can be asserted without a
    /// real lock session.
    private(set) var isPresentingOnLockScreen = false

    /// M9: set the moment THIS presenter is the one that called
    /// `nowPlaying.setActive(true)` to keep the media pill fresh while
    /// locked — see `shouldActivateForLock`'s own doc comment for the full
    /// ownership contract. `false` the rest of the time, including whenever
    /// the Now Playing widget itself was already active at lock time (this
    /// presenter never touched it, so it has nothing to undo on unlock).
    private var didActivateForLock = false

    /// M9: guards against a second `"com.apple.screenIsUnlocked"` delivery
    /// (that notification isn't documented as strictly one-shot per unlock,
    /// the same "not documented, treat as a nudge, never trust it blindly"
    /// posture this whole type already takes toward both notification names
    /// — see the type doc comment's point 1) re-playing the unlock sound and
    /// re-starting the fade-out on a panel that's already mid-fade. Set the
    /// instant the first `handleUnlocked()` actually starts tearing things
    /// down; cleared once the panel is actually gone (`dismissImmediately`)
    /// or a fresh lock arrives (`handleLocked`) and decides the panel should
    /// stay/fade back up instead.
    private var isDismissing = false

    init(nowPlaying: NowPlayingService, activities: LiveActivityCenter, settings: SettingsStore) {
        self.nowPlaying = nowPlaying
        self.activities = activities
        self.settings = settings
    }

    deinit {
        // Observer-free teardown: `AnyCancellable`'s own deinit cancels each
        // Combine subscription when this set is released, `fadeOutDeadline`
        // is its own object (its own `deinit` cancels whatever's pending —
        // see `DeadlineTask`'s doc comment) rather than something this type
        // needs to cancel itself, and `NSPanel.orderOut`/dropping `panel`
        // needs no explicit call here either — none of it depends on `self`
        // surviving past this point.
    }

    /// The single on/off gate — mirrors every other notch-suite `setEnabled`
    /// (`NotchWindowController.setEnabled`, `NotchWidgetRegistry.setEnabled`,
    /// `VolumeMonitor`'s start/stop shape): turning this off tears
    /// EVERYTHING down — the `DistributedNotificationCenter`/settings
    /// observers AND any panel currently showing (instantly, no fade — this
    /// is the master switch turning the whole experiment off, not an
    /// ordinary unlock) — so a disabled experiment costs nothing at idle: no
    /// observer, no window, nothing left that could misfire.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            startObserving()
        } else {
            stopObserving()
            dismissImmediately()
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

        // Live-update the already-showing panel's pill visibility the moment
        // any of the three sub-feature toggles changes, without waiting for
        // the next lock/unlock cycle. In practice the lock screen itself
        // blocks reaching Settings while locked, so this mostly matters
        // right after `setEnabled(true)` (seeding a freshly-enabled
        // experiment's flags) and as defensive belt-and-suspenders — see
        // `updateHostingContent`'s own doc comment.
        // Passes the sink's own emitted tuple straight into
        // `updateHostingContent`/`makeContentView` rather than having them
        // re-read `settings.notchLockScreen*Enabled` — `@Published` delivers
        // via `willSet`, so a sink that re-reads the stored properties
        // instead of using its own emitted values would see the OLD ones,
        // one toggle behind (the same stale-`willSet`-read class documented
        // elsewhere in this codebase, e.g. `NotchActivityRouter`'s several
        // `observe*Gating` sinks and `AppDelegate.configureLockScreenPresenter`).
        settings.$notchLockScreenNowPlayingEnabled
            .combineLatest(settings.$notchLockScreenActivitiesEnabled, settings.$notchLockScreenUnlockPillEnabled)
            .dropFirst()
            .sink { [weak self] nowPlayingEnabled, activitiesEnabled, unlockPillEnabled in
                self?.updateHostingContent(allowNowPlaying: nowPlayingEnabled,
                                            allowActivities: activitiesEnabled,
                                            showUnlockPill: unlockPillEnabled)
            }
            .store(in: &cancellables)
    }

    /// No-op if not observing. Cancels every subscription above by dropping
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
    /// this content to sit over, so this does nothing at all rather than
    /// drawing an arbitrary rectangle somewhere on an external display.
    ///
    /// Cancels any in-flight fade-out-then-dismiss FIRST, unconditionally —
    /// the rapid lock/unlock-cycling fix: a lock arriving while a previous
    /// unlock's fade is still winding down must never let that fade's
    /// pending `orderOut` fire later and tear down the panel this new lock
    /// just decided should stay (or fade back) up.
    ///
    /// If a panel is ALREADY up (a second `"com.apple.screenIsLocked"`
    /// arrives with no intervening unlock — this notification's own delivery
    /// isn't documented as strictly one-shot per lock, and screen-lock/wake
    /// races are exactly the kind of thing that can double-fire it), this
    /// refreshes that existing panel's content/position in place rather than
    /// building a brand new one: `showPanel` unconditionally overwrites
    /// `panel` with a fresh `NSPanel`, and dropping the old Swift reference
    /// does NOT order the old window out — it simply orphans it, still
    /// showing, above the lock screen shield, with nothing left able to
    /// dismiss it on the next unlock (`dismissImmediately()`/
    /// `fadeOutThenDismiss()` only ever know about the CURRENT `panel`).
    private func handleLocked() {
        fadeOutDeadline.cancel()
        // A fresh lock always supersedes any dismiss still winding down (or
        // one that already finished) — see `isDismissing`'s own doc comment
        // for why this must be unconditional here, the same reasoning
        // `fadeOutDeadline.cancel()` right above already applies to the
        // pending-dismiss deadline itself.
        isDismissing = false
        guard isEnabled else { return }
        guard let screen = NSScreen.builtInNotchedScreen, let notchRect = screen.notchRect else { return }
        if let panel {
            refreshPanel(panel, on: screen, notchRect: notchRect)
        } else {
            showPanel(on: screen, notchRect: notchRect)
        }
    }

    /// Plays the optional unlock sound (gated on its own settings toggle,
    /// read live — see `playUnlockSoundIfEnabled`) and starts the fade-out;
    /// a no-op with no panel currently up (an unlock with the experiment
    /// disabled, or one that raced ahead of any lock ever actually showing
    /// a panel) OR with a dismiss already in flight (`isDismissing` — a
    /// second `"com.apple.screenIsUnlocked"` delivery for the same unlock
    /// must not replay the sound or restart the fade on a panel that's
    /// already fading; see that flag's own doc comment).
    private func handleUnlocked() {
        guard let panel, !isDismissing else { return }
        isDismissing = true
        playUnlockSoundIfEnabled()
        fadeOutThenDismiss(panel)
    }

    // MARK: - Panel

    private func showPanel(on screen: NSScreen, notchRect: NSRect) {
        currentNotchSize = notchRect.size
        activateNowPlayingForLockIfNeeded()
        let panel = makePanel(notchSize: notchRect.size)
        self.panel = panel
        position(panel, on: screen, notchRect: notchRect)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isPresentingOnLockScreen = true
        animateAlpha(of: panel, to: 1, duration: Self.fadeInDuration)
    }

    /// Updates an already-showing panel's content/position in place instead
    /// of building a new one — the `handleLocked()` re-entry path. Content
    /// itself only needs re-derivation here for `notchSize` (a screen change
    /// mid-lock is exotic but not impossible) and the `allow*`/
    /// `showUnlockPill` flags; the Now Playing/activity DATA those pills
    /// show is already live via `LockScreenContentView`'s own
    /// `@ObservedObject` bindings, so there is nothing to re-inject there.
    /// Also resumes the fade-in from wherever alpha currently sits (a lock
    /// arriving while a still-in-progress fade-out is winding down — the
    /// task itself was already cancelled by `handleLocked` before this runs)
    /// rather than snapping to fully visible.
    private func refreshPanel(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        currentNotchSize = notchRect.size
        updateHostingContent()
        position(panel, on: screen, notchRect: notchRect)
        panel.orderFrontRegardless()
        isPresentingOnLockScreen = true
        if panel.alphaValue < 1 {
            animateAlpha(of: panel, to: 1, duration: Self.fadeInDuration)
        }
    }

    /// Fades `panel`'s alpha to 0 over `fadeOutDuration`, then — once that's
    /// actually finished, via `fadeOutDeadline` (a cancellable deadline, not
    /// an `NSAnimationContext` completion handler) — orders it out and
    /// releases it. The deadline (not the animation itself) is what
    /// `handleLocked()` cancels on a rapid re-lock: cancelling only stops the
    /// PENDING dismiss, not the in-flight alpha animation, but that's fine —
    /// `handleLocked()`'s own `refreshPanel`/`showPanel` immediately re-
    /// targets alpha back toward 1 right after, and `NSAnimationContext`
    /// animations smoothly retarget mid-flight rather than glitching.
    private func fadeOutThenDismiss(_ panel: NSPanel) {
        animateAlpha(of: panel, to: 0, duration: Self.fadeOutDuration)
        fadeOutDeadline.reschedule(to: Date().addingTimeInterval(Self.fadeOutDuration)) { [weak self] in
            self?.dismissImmediately()
        }
    }

    /// Orders out and releases the panel with no fade — used by the master
    /// `setEnabled(false)` switch (an instant, unconditional teardown, not
    /// an ordinary unlock) and as the fade-out deadline's own completion.
    /// Cancels any still-pending fade-out deadline first (idempotent — this
    /// IS that deadline's own completion in the ordinary case, where nothing
    /// is left pending by the time this runs). Safe to call whether or not a
    /// panel currently exists.
    private func dismissImmediately() {
        fadeOutDeadline.cancel()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        isPresentingOnLockScreen = false
        // The panel is actually gone now — the point `isDismissing`'s own
        // doc comment calls out as the other place (besides a fresh lock)
        // that clears it.
        isDismissing = false
        deactivateNowPlayingForLockIfNeeded()
    }

    /// M9 (lock-screen Now Playing freshness): the media pill only ever
    /// re-renders in response to `NowPlayingService.state` actually
    /// changing, and `state` only changes while the service is `isActive`
    /// (see `NowPlayingService.setActive`'s own doc comment on why the
    /// scripting poll — the one piece of this pipeline that costs anything
    /// while idle — is gated on it). Nothing else keeps that flag on while
    /// the screen is locked: the Now Playing widget only calls `setActive`
    /// from its own presentation lifecycle, and there is no widget
    /// presented at all on the lock screen. Without this, the media pill
    /// would only ever show whatever was already active the instant the
    /// screen locked, then silently go stale for the rest of the session.
    ///
    /// Ownership is intentionally simple, not ref-counted: `didActivateForLock`
    /// records whether THIS call is the one that flipped the service on, so
    /// the matching `deactivateNowPlayingForLockIfNeeded()` on unlock only
    /// ever undoes what this presenter itself did. If the Now Playing widget
    /// was already active at lock time (its own owner already holds
    /// `setActive(true)`), `shouldActivateForLock` returns `false`,
    /// `didActivateForLock` stays `false`, and unlock leaves the widget's
    /// own activation completely alone — this presenter simply never
    /// touches a service some other owner is already keeping alive. The one
    /// accepted gap: if the widget itself calls `setActive(false)` while
    /// still locked (e.g. the user closes the notch panel mid-lock on a
    /// build where that's reachable), this presenter has no way to notice
    /// and reclaim ownership until the NEXT lock — `NowPlayingService`
    /// tracks a single `isActive` bool, not a set of owners, so there is no
    /// richer signal to observe here. That's an acceptable trade for a
    /// permission-free, privacy-neutral adapter call (the AppleScript
    /// scripting consent gate lives inside the service itself, entirely
    /// unaffected by this) rather than real reference counting for a
    /// best-effort lock-screen convenience feature.
    private func activateNowPlayingForLockIfNeeded() {
        guard Self.shouldActivateForLock(serviceActive: nowPlaying.isActive,
                                          masterEnabled: isEnabled,
                                          nowPlayingAllowed: settings.notchLockScreenNowPlayingEnabled)
        else { return }
        nowPlaying.setActive(true)
        didActivateForLock = true
    }

    /// The unlock-side half of `activateNowPlayingForLockIfNeeded` — see that
    /// function's doc comment for the full ownership contract. A no-op
    /// whenever this presenter never activated the service in the first
    /// place (`didActivateForLock == false`), which covers both "Now Playing
    /// was never enabled for the lock screen" and "the widget already owned
    /// activation at lock time."
    private func deactivateNowPlayingForLockIfNeeded() {
        guard didActivateForLock else { return }
        didActivateForLock = false
        nowPlaying.setActive(false)
    }

    /// Pure decision behind `activateNowPlayingForLockIfNeeded` — extracted
    /// so `--selftest` can assert the on/off matrix directly, since this
    /// environment can't run a real lock session.
    static func shouldActivateForLock(serviceActive: Bool, masterEnabled: Bool, nowPlayingAllowed: Bool) -> Bool {
        masterEnabled && nowPlayingAllowed && !serviceActive
    }

    /// Rebuilds the hosted view's plain (non-`@ObservedObject`) inputs —
    /// `notchSize` and the three `allow*`/`showUnlockPill` settings-derived
    /// flags — in place. `nowPlaying`/`activities` are the exact same
    /// instances either way (this only ever reassigns `hostingView.rootView`
    /// with a fresh `LockScreenContentView` value wrapping the SAME object
    /// references), so this never disrupts their own live `@ObservedObject`
    /// updates; it only exists for the handful of inputs SwiftUI can't
    /// observe on its own. A no-op with no panel currently up.
    private func updateHostingContent() {
        updateHostingContent(allowNowPlaying: settings.notchLockScreenNowPlayingEnabled,
                              allowActivities: settings.notchLockScreenActivitiesEnabled,
                              showUnlockPill: settings.notchLockScreenUnlockPillEnabled)
    }

    /// The sink-facing overload above — takes the three flags explicitly
    /// rather than reading `settings` itself, so the settings-changed sink in
    /// `startObserving` can hand this its own freshly-emitted values instead
    /// of this function re-reading (and risking a stale `willSet`-era read
    /// of) the same properties. The no-arg overload above is what
    /// `showPanel`/`refreshPanel` call, where reading `settings` live is
    /// exactly right (they're not running inside that sink at all).
    private func updateHostingContent(allowNowPlaying: Bool, allowActivities: Bool, showUnlockPill: Bool) {
        guard let hostingView else { return }
        hostingView.rootView = makeContentView(allowNowPlaying: allowNowPlaying,
                                                allowActivities: allowActivities,
                                                showUnlockPill: showUnlockPill)
    }

    private func makeContentView() -> LockScreenContentView {
        makeContentView(allowNowPlaying: settings.notchLockScreenNowPlayingEnabled,
                         allowActivities: settings.notchLockScreenActivitiesEnabled,
                         showUnlockPill: settings.notchLockScreenUnlockPillEnabled)
    }

    private func makeContentView(allowNowPlaying: Bool, allowActivities: Bool, showUnlockPill: Bool) -> LockScreenContentView {
        LockScreenContentView(
            notchSize: currentNotchSize,
            nowPlaying: nowPlaying,
            activities: activities,
            allowNowPlaying: allowNowPlaying,
            allowActivities: allowActivities,
            showUnlockPill: showUnlockPill)
    }

    /// Builds the lock-screen panel: the `NotchHighlightWindow` recipe
    /// (borderless, nonactivating, clear, `.canJoinAllSpaces`/
    /// `.fullScreenAuxiliary`/`.stationary` — see that type's own doc
    /// comment) but at `shieldedLevel` instead of `.statusBar`, and — this is
    /// the safety-critical line — `ignoresMouseEvents = true`. The lock
    /// screen's own password field/UI sits at (or below) the shield level
    /// this panel draws just above; without `ignoresMouseEvents`, a
    /// borderless-but-still-hit-testable panel spanning that space could
    /// intercept clicks/keystrokes meant for actually unlocking the Mac.
    /// `LockScreenContentView` has no interactive content at all (see its
    /// own doc comment), so there is nothing lost by making that explicit
    /// and unconditional here.
    private func makePanel(notchSize: CGSize) -> NSPanel {
        let hosting = NSHostingView(rootView: makeContentView())
        self.hostingView = hosting

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

    /// Centers the panel on the notch, top-anchored, with a fixed height
    /// budget generous enough for the silhouette plus all three stacked
    /// pills at once (the common case shows fewer — the extra vertical space
    /// is simply empty and transparent, since `LockScreenContentView`'s own
    /// `VStack` is top-aligned within it) and a width wide enough for the
    /// ~260pt-wide media pill, which is itself wider than the physical notch
    /// on every current Mac. Mirrors `NotchWindowController.position`'s
    /// identical centering math, just against this feature's own (larger,
    /// pill-stack-sized) bounds rather than `NotchMetrics.panelBounds`.
    private func position(_ panel: NSPanel, on screen: NSScreen, notchRect: NSRect) {
        let width = max(notchRect.width, Self.minPanelWidth)
        let height = notchRect.height + Self.contentHeightBudget
        let origin = NSPoint(x: notchRect.midX - width / 2, y: screen.frame.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private static let minPanelWidth: CGFloat = 280
    /// Silhouette + 3 pills (media ~34pt, activity ~24pt, unlock ~24pt) +
    /// 3 `NotchDesign.space2` (8pt) gaps between them, rounded up with a
    /// little slack.
    private static let contentHeightBudget: CGFloat = 140

    private static let fadeInDuration: TimeInterval = 0.4
    private static let fadeOutDuration: TimeInterval = 0.25

    /// Animates `panel`'s `alphaValue` via `NSAnimationContext` (a real,
    /// Core-Animation-backed window fade — not a repeating `Timer`/`Task`
    /// loop of manual alpha steps) with an ease-out timing curve, matching
    /// the build spec's "fade in 0.4s ease-out, fade out 0.25s" — the
    /// PENDING-dismiss half of a fade-out is the only part that needs an
    /// actual cancellable deadline (`fadeOutDeadline`, see
    /// `fadeOutThenDismiss`); the visual animation itself is a one-line
    /// AppKit call either direction.
    private func animateAlpha(of panel: NSPanel, to value: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = value
        }
    }

    /// Best-effort, quietly defensive: `NSSound(named:)` returns `nil` for a
    /// missing/renamed system sound rather than throwing, and `.play()`
    /// returns `Bool` rather than throwing either — both are simply ignored
    /// on failure, since a lock-screen sound failing to play is never worth
    /// surfacing anywhere, let alone worth crashing over. Reads the setting
    /// live (rather than caching it) since this only ever runs once per
    /// unlock — there's no long-lived state to keep in sync the way the
    /// pill-visibility flags need `updateHostingContent` for.
    private func playUnlockSoundIfEnabled() {
        guard settings.notchLockScreenUnlockSoundEnabled else { return }
        NSSound(named: "Glass")?.play()
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
