import AppKit
import CoreGraphics
import Darwin

/// `DisplayServicesGetBrightness`'s C signature — an `Int32` status (`0` on
/// success) and an out-param for the current 0...1 brightness scalar.
private typealias DisplayServicesGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
/// `DisplayServicesSetBrightness`'s C signature — same status convention,
/// writing a new 0...1 brightness scalar.
private typealias DisplayServicesSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
/// `DisplayServicesCanChangeBrightness`'s C signature — a plain predicate;
/// some displays (or a brightness locked by an MDM profile) refuse changes
/// even when the two functions above exist and load fine.
private typealias DisplayServicesCanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Bool

/// Reads/writes the built-in display's brightness via `DisplayServices`, a
/// **private** framework with no public replacement — `IODisplay`'s old
/// documented brightness API doesn't work on Apple Silicon Macs at all, and
/// every third-party brightness utility (this app's direct M5 HUD
/// competitors included) relies on these same private entry points.
///
/// ## Why `dlopen`/`dlsym` rather than linking the framework
/// Weak-linking a private framework at build time still requires it to exist
/// at the exact path — and export the exact symbols — on whatever OS version
/// this binary eventually runs on; Apple gives zero compatibility guarantee
/// for anything in `PrivateFrameworks`. Loading it dynamically at runtime and
/// tolerating a missing handle/symbol as "just not available"
/// (`isAvailable = false`) is the same defensive posture as
/// `NowPlayingSource`'s own MediaRemote-adapter fallback: the brightness half
/// of the M5 HUD degrades to silently doing nothing — never crashing, never
/// failing to launch — if a future macOS ever renames or removes these
/// symbols. `NotchActivityRouter` reads `isAvailable` once (right after
/// constructing this) to decide whether `MediaKeyInterceptor` should ever
/// swallow a brightness key at all (see that class's `shouldSwallow`).
///
/// ## Why intercept-mode-only (no observe mode for brightness)
/// Unlike CoreAudio's volume, macOS exposes no change *notification* for
/// display brightness at all — there is nothing to add a listener to. The
/// only way to detect a brightness key press without already intercepting it
/// via `MediaKeyInterceptor` would be polling, which would cost a perpetual
/// timer wakeup even at idle — a direct violation of this app's 0%-idle-CPU
/// contract. So brightness only ever changes here as the *result* of an
/// already-parsed, already-swallowed key press (`NotchActivityRouter.applyBrightnessKey`);
/// this class never independently watches for anything on its own.
@MainActor
final class BrightnessMonitor {
    /// `false` when the private framework or either required symbol
    /// couldn't be loaded — every method below becomes a no-op / returns
    /// `nil` rather than every caller needing its own availability check
    /// first.
    private(set) var isAvailable: Bool

    private let handle: UnsafeMutableRawPointer?
    private let getBrightnessFn: DisplayServicesGetBrightnessFn?
    private let setBrightnessFn: DisplayServicesSetBrightnessFn?
    private let canChangeFn: DisplayServicesCanChangeBrightnessFn?

    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    init() {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            hudLog.notice("BrightnessMonitor: dlopen(DisplayServices) failed — brightness HUD/intercept unavailable, volume HUD unaffected")
            self.handle = nil
            getBrightnessFn = nil
            setBrightnessFn = nil
            canChangeFn = nil
            isAvailable = false
            return
        }

        func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        self.handle = handle
        getBrightnessFn = loadSymbol("DisplayServicesGetBrightness", as: DisplayServicesGetBrightnessFn.self)
        setBrightnessFn = loadSymbol("DisplayServicesSetBrightness", as: DisplayServicesSetBrightnessFn.self)
        canChangeFn = loadSymbol("DisplayServicesCanChangeBrightness", as: DisplayServicesCanChangeBrightnessFn.self)
        isAvailable = getBrightnessFn != nil && setBrightnessFn != nil
        if !isAvailable {
            hudLog.notice("BrightnessMonitor: DisplayServices loaded but is missing a required symbol — brightness HUD/intercept unavailable")
        }
    }

    deinit {
        // Mirrors `VolumeMonitor.deinit`/`MediaKeyInterceptor.deinit`: plain
        // teardown of what this instance itself opened, called directly from
        // a nonisolated `deinit` rather than routed through an instance
        // method. `dlclose` is a no-op-safe call to skip entirely when
        // `dlopen` itself never succeeded (`handle == nil`).
        if let handle {
            dlclose(handle)
        }
    }

    /// The built-in panel's `CGDirectDisplayID` — reuses
    /// `NSScreen.builtInNotchedScreen` (`MenuBarGeometry.swift`) rather than
    /// re-deriving "the internal display" from `CGGetOnlineDisplayList`
    /// itself: every Mac with a notch is a laptop with exactly one built-in
    /// panel, so the screen the notch suite already resolves for its own
    /// panel placement is the same one brightness should act on. `nil` when
    /// there's no notched built-in screen at all — brightness intercept has
    /// nowhere to show its HUD in that case anyway.
    private static func targetDisplay() -> CGDirectDisplayID? {
        NSScreen.builtInNotchedScreen?.displayID
    }

    /// Whether THIS display's brightness can actually be changed right now —
    /// `isAvailable` (the DisplayServices symbols loaded) AND
    /// `DisplayServicesCanChangeBrightness` reports true for the built-in
    /// display. The code-review fix this backs: `isAvailable` alone only
    /// means the symbols exist, not that a change would succeed — some
    /// configurations (an MDM-enforced brightness lock, certain external/
    /// non-standard panels) load the framework fine but categorically refuse
    /// `DisplayServicesSetBrightness`. `NotchActivityRouter` gates
    /// brightness-key swallowing on this rather than bare `isAvailable`, so a
    /// key this app can't actually act on passes through instead of being
    /// silently eaten. When `canChangeFn` itself failed to load, this falls
    /// back to the same permissive assumption `setBrightness` already makes
    /// (`if let canChangeFn, !canChangeFn(display)` — no function means no
    /// veto, not an automatic refusal) rather than a second, stricter
    /// standard.
    var canChangeBrightness: Bool {
        guard isAvailable, let display = Self.targetDisplay() else { return false }
        guard let canChangeFn else { return true }
        return canChangeFn(display)
    }

    /// Current brightness (0...1), or `nil` when unavailable, there's no
    /// built-in notched display, or the read itself failed.
    func getBrightness() -> Float? {
        guard isAvailable, let getBrightnessFn, let display = Self.targetDisplay() else { return nil }
        var value: Float = 0
        return getBrightnessFn(display, &value) == 0 ? value : nil
    }

    /// Clamps to 0...1 before writing. Returns `false` (a no-op) when
    /// unavailable, there's no target display, or
    /// `DisplayServicesCanChangeBrightness` reports this display refuses
    /// changes.
    @discardableResult
    func setBrightness(_ level: Float) -> Bool {
        guard isAvailable, let setBrightnessFn, let display = Self.targetDisplay() else { return false }
        if let canChangeFn, !canChangeFn(display) { return false }
        return setBrightnessFn(display, min(max(level, 0), 1)) == 0
    }

    /// Reads the current level, applies `delta`, and writes back the result
    /// clamped to 0...1 — returning the level actually written so
    /// `NotchActivityRouter` can post the HUD activity with the exact value
    /// now in effect rather than assuming the write succeeded at the
    /// requested value. `nil` on any failure along the way (unavailable, no
    /// display, read failed, write refused).
    @discardableResult
    func adjust(by delta: Float) -> Float? {
        guard let current = getBrightness() else { return nil }
        let target = min(max(current + delta, 0), 1)
        return setBrightness(target) ? target : nil
    }
}
