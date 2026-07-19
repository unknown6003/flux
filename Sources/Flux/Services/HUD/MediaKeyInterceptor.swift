import AppKit
import CoreGraphics
import Combine

/// A logical HUD key extracted from an `NX_SYSDEFINED` system-defined event —
/// the private-but-decades-stable vocabulary macOS uses for volume/
/// brightness/media keys pressed anywhere in the system, independent of any
/// keyboard layout (the standard `NSEvent` character-key vocabulary doesn't
/// cover these at all).
enum HUDKey: Equatable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

/// `MediaKeyInterceptor`'s public event: one swallowed HUD key press. `fine`
/// mirrors the Shift+Option "small step" modifier macOS itself recognizes on
/// these keys (a 1/64 nudge instead of the normal 1/16 step); `isRepeat`
/// threads through `NX_SYSDEFINED`'s own autorepeat bit, though
/// `NotchActivityRouter` currently applies the same one-step action either
/// way — the repeat *cadence* while a key is held is what makes the change
/// feel continuous, not a bigger per-tick step.
enum HUDKeyEvent: Equatable {
    case key(HUDKey, isRepeat: Bool, fine: Bool)
}

/// Swallows the system's volume/mute/brightness keys at the session level via
/// a `CGEventTap`, so Flux's own notch HUD can be the *only* UI that reacts —
/// no system bezel — for the "intercept mode" half of the M5 HUD design (see
/// `VolumeMonitor`'s and `BrightnessMonitor`'s doc comments for "observe
/// mode," the permission-free alternative this app falls back to).
///
/// ## Why session-level, and why it needs Accessibility
/// Volume/brightness keys arrive as `NX_SYSDEFINED` (`CGEventType(rawValue:
/// 14)`, a private-but-stable event type every media-key utility on macOS —
/// sanctioned or not — taps the same way) rather than any public
/// `CGEventType` case. A session event tap that can actually *consume* one
/// (`.defaultTap`, not `.listenOnly`) requires the process to be
/// Accessibility-trusted; `CGEvent.tapCreate` simply hands back `nil` when it
/// isn't, which `start()` surfaces as a `Bool` return so the caller
/// (`NotchActivityRouter`) can fall back to observe mode instead of assuming
/// success.
///
/// ## The C-callback interop
/// `CGEvent.tapCreate`'s callback is a plain `@convention(c)` function
/// pointer — it cannot capture `self` — so this uses the same `Unmanaged`
/// context-pointer dance as `PowerMonitor.start()`/`HotkeyManager`'s Carbon
/// handler: `Unmanaged.passUnretained(self).toOpaque()` goes in as
/// `userInfo` at creation time, and the callback reconstructs `self` from
/// that pointer. The run-loop source is always added to `CFRunLoopGetMain()`
/// (never `GetCurrent()`, so `stop()`/`deinit` can safely remove it
/// regardless of which thread they happen to run on — mirrors
/// `PowerMonitor`'s choice for the same reason), which is what makes
/// `MainActor.assumeIsolated` inside the callback a real assertion rather
/// than a hopeful guess.
///
/// The callback itself does only the minimum needed to decide swallow-vs-pass
/// synchronously (required — that decision *is* the callback's return value):
/// parse the event, map it to a `HUDKey`, and check `brightnessAvailable`.
/// The actual downstream work (adjusting CoreAudio/DisplayServices, posting a
/// live activity) is handed off via `Task { @MainActor in ... }` rather than
/// run inline, so a slow subscriber can never make the tap itself look
/// unresponsive to the system — macOS disables an event tap outright if its
/// callback takes too long to return (see `handleTapEvent`'s
/// `.tapDisabledByTimeout` handling below).
@MainActor
final class MediaKeyInterceptor {
    let events = PassthroughSubject<HUDKeyEvent, Never>()

    /// Whether brightness keys should be swallowed at all — mirrors
    /// `BrightnessMonitor.canChangeBrightness` (not the weaker `isAvailable`:
    /// the symbols loading isn't the same as THIS display actually accepting
    /// a change). Brightness keys pass through untouched when `false` (there's
    /// no private API left to act on them with, or this display refuses
    /// anyway), even while volume keys are still fully intercepted;
    /// `NotchActivityRouter` sets this right before a successful `start()`.
    var brightnessAvailable = false

    /// Whether the CURRENT default output device can actually have its
    /// volume changed at all — `false` for several digital/HDMI outputs and
    /// some external DACs, which expose no software-settable volume scalar.
    /// Consulted by `shouldSwallow` the same way `brightnessAvailable` gates
    /// brightness keys: swallowing a volume key this app then can't act on
    /// would silently take away the user's only volume control, with no
    /// system bezel to fall back on. Defaults to `{ true }` (the pre-fix,
    /// always-swallow behavior) so an interceptor built without this wired
    /// — e.g. directly in a test — behaves exactly as before; `NotchActivityRouter`
    /// wires this to `VolumeMonitor.hasVolumeControl` in production. A closure
    /// rather than a stored `Bool` because the answer can change out from
    /// under a live tap (the default output device switching to one with a
    /// different capability) without anything re-wiring this property.
    var volumeControllable: () -> Bool = { true }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// `NX_SYSDEFINED` — the private system-event type every volume/
    /// brightness/media key arrives as. Not part of the public `CGEventType`
    /// enum, hence the raw value rather than a case name.
    private static let nxSystemDefinedRawValue: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS` — the `NSEvent.subtype` every media
    /// key (as opposed to some other private system-defined event) carries.
    private static let auxControlButtonsSubtype: Int16 = 8

    // MARK: - Lifecycle

    /// Attempts to create and enable the event tap. Returns `false` — and
    /// leaves this instance in exactly the state it was in before the call,
    /// safe to retry later (e.g. right after the user grants Accessibility)
    /// — when the tap can't be created, almost always because the process
    /// isn't Accessibility-trusted yet.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = 1 << Self.nxSystemDefinedRawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passRetained(cgEvent) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                // Safe (not just hopeful): `start()` only ever adds this
                // tap's run-loop source to `CFRunLoopGetMain()`, so this
                // callback always fires synchronously on the main thread.
                return MainActor.assumeIsolated {
                    interceptor.handleTapEvent(type: type, cgEvent: cgEvent)
                }
            },
            userInfo: context
        ) else {
            hudLog.error("MediaKeyInterceptor: CGEvent.tapCreate failed — Accessibility not granted, or the tap was refused")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            hudLog.error("MediaKeyInterceptor: failed to create a run-loop source for the event tap")
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Whether the tap is actually live right now — non-`nil` AND still
    /// enabled, rather than just "we successfully called `start()` at some
    /// point in the past." `CGEvent.tapCreate`'s tap can go dark later
    /// without this object ever hearing about it directly (a revoked
    /// Accessibility grant, or the timeout path that `handleTapEvent`
    /// usually — but not unconditionally — recovers from); `NotchActivityRouter`
    /// re-derives its own `interceptorActive` reasoning from this rather than
    /// trusting a stored flag set only at the moment `start()` last returned,
    /// so a dead tap is noticed and cleaned up instead of permanently
    /// blocking re-arm.
    var isTapActive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func stop() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
    }

    deinit {
        // Plain CF teardown calls, not `self.stop()` — mirrors
        // `PowerMonitor.deinit`'s reasoning for the same shape.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    // MARK: - Tap callback

    private func handleTapEvent(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap after a timeout (or the user invoking
        // Secure Input, e.g. typing a password) rather than tearing it down —
        // re-enabling immediately is the documented recovery, and this event
        // itself carries no key data to act on either way.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(cgEvent)
        }

        // Reviewed and accepted: bridging to `NSEvent` per tap event (rather
        // than reading `data1`/`subtype` straight off `CGEvent` via
        // `CGEventField`) is the established parse path for `NX_SYSDEFINED`
        // every media-key utility on macOS uses — SlimHUD and its many
        // relatives included — precisely because `data1`/`subtype` have no
        // public `CGEventField` at all; `NSEvent(cgEvent:)` is the only
        // documented bridge that surfaces them. Direct `CGEventField`
        // access to the underlying NX data would mean poking at the same
        // private layout through an even less-sanctioned path for no
        // measured benefit — revisit only if profiling ever shows the
        // per-event bridge itself (as opposed to the tap overall) costing
        // something on the callback's hot path.
        guard type.rawValue == Self.nxSystemDefinedRawValue,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype
        else {
            return Unmanaged.passRetained(cgEvent)
        }

        let parsed = Self.parseKeyEvent(data1: nsEvent.data1)
        guard let key = Self.hudKey(forNXKeyCode: parsed.keyCode) else {
            return Unmanaged.passRetained(cgEvent)
        }
        guard Self.shouldSwallow(key: key, brightnessAvailable: brightnessAvailable,
                                  volumeControllable: volumeControllable())
        else {
            return Unmanaged.passRetained(cgEvent)
        }

        // Only the key-down edge drives an action — autorepeat while held
        // resends key-down repeatedly (that's `isRepeat`'s cadence), and the
        // matching key-up carries nothing worth acting on. Both are still
        // swallowed (returning `nil` unconditionally below) so the system
        // never sees an orphaned half of the pair.
        if parsed.keyDown {
            let fine = Self.isFineStep(flags: cgEvent.flags)
            Task { @MainActor [weak self] in
                self?.events.send(.key(key, isRepeat: parsed.isRepeat, fine: fine))
            }
        }
        return nil
    }

    // MARK: - Pure parsing/decision logic (testable without a real tap)

    /// Cracks `NX_SYSDEFINED`'s packed `data1` field. Layout (from Apple's
    /// private `IOKit/hidsystem/ev_keymap.h`, the same bit layout every
    /// media-key utility on macOS — sanctioned or not — has relied on for
    /// decades): bits 16-31 are the `NX_KEYTYPE_*` key code, bits 8-15 of the
    /// low word are the key state (`0xA` down, `0xB` up), and bit 0 is the
    /// autorepeat flag.
    static func parseKeyEvent(data1: Int) -> (keyCode: Int, keyDown: Bool, isRepeat: Bool) {
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isRepeat = (keyFlags & 0x1) != 0
        return (keyCode, keyState == 0xA, isRepeat)
    }

    /// Maps an `NX_KEYTYPE_*` code to the `HUDKey` this app acts on. `nil`
    /// for every other system-defined key (play/pause and the like) — those
    /// pass through untouched.
    static func hudKey(forNXKeyCode keyCode: Int) -> HUDKey? {
        switch keyCode {
        case 0: return .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: return .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        case 7: return .mute            // NX_KEYTYPE_MUTE
        case 2: return .brightnessUp    // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: return .brightnessDown  // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return nil
        }
    }

    /// Volume keys are swallowed only when `volumeControllable` — some
    /// digital/HDMI outputs and external DACs expose no software volume
    /// control at all, and swallowing the key anyway would take away the
    /// user's only way to adjust volume with zero feedback (no system bezel,
    /// no app response either). Brightness keys are only swallowed when
    /// `brightnessAvailable`, for the exact same reason on the DisplayServices
    /// side; otherwise letting either pass straight through is strictly
    /// better than swallowing a key this app then can't actually act on.
    static func shouldSwallow(key: HUDKey, brightnessAvailable: Bool, volumeControllable: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute: return volumeControllable
        case .brightnessUp, .brightnessDown: return brightnessAvailable
        }
    }

    /// The Shift+Option "fine step" modifier macOS itself recognizes on
    /// volume/brightness keys (a 1/64 nudge vs. the normal 1/16 step).
    static func isFineStep(flags: CGEventFlags) -> Bool {
        flags.contains(.maskShift) && flags.contains(.maskAlternate)
    }

    /// Whether Accessibility is currently granted — the precondition
    /// `start()` needs to succeed. `NotchActivityRouter` checks this before
    /// even attempting `start()`, both to avoid a doomed call and so it never
    /// tries to escalate into intercept mode while the toggle is on but the
    /// permission itself is denied or was revoked.
    static func isAccessibilityGranted(_ permissions: PermissionCenter) -> Bool {
        permissions.statuses[.accessibility] == .granted
    }
}
