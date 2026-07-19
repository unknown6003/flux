import Foundation
import Combine
import IOKit.ps
import OSLog

/// Shared logging point for the power subsystem — mirrors `shelfLog`'s
/// file-scope-constant pattern rather than adding a new case to `Log.swift`,
/// since this is a self-contained M3 subsystem the notch suite owns.
let powerLog = Logger(subsystem: "com.flux.menubar", category: "power")

/// What's true about the battery/AC power right now. `Equatable` so the
/// internal `previousState` diff only treats an actual change as a
/// transition, and so `--selftest` can compare snapshots directly.
struct PowerState: Equatable {
    var percent: Int
    var isCharging: Bool
    var onACPower: Bool
}

/// A discrete moment worth surfacing as a live activity — as opposed to
/// `PowerState`, which is just "what's true right now." Computed by diffing
/// consecutive `PowerState` snapshots (see `PowerMonitor.plugEvent` /
/// `PowerMonitor.lowBatteryEvent`).
enum PowerEvent: Equatable {
    case pluggedIn(percent: Int)
    case unplugged(percent: Int)
    case lowBattery(percent: Int)
    /// The percent climbed back above the re-arm threshold *without* a plug
    /// event in between — e.g. a noisy read recovering, or external charging
    /// hardware IOKit doesn't report as AC. Only fired when a `.lowBattery`
    /// had actually been posted (see `lowBatteryEvent`'s doc comment); tells
    /// `NotchActivityRouter` its sticky low-battery warning is stale and
    /// should come down even though nothing plugged in to replace it.
    case batteryRecovered(percent: Int)
}

/// Watches IOKit's power-source publisher for battery percent / charging /
/// AC-power changes, diffs consecutive `PowerState` snapshots internally
/// (`previousState`), and turns that into discrete `PowerEvent`s (`events`)
/// that `NotchActivityRouter` turns into live activities. No published
/// snapshot of its own — nothing outside this type has ever needed one; see
/// the M3 review that dropped the prior `@Published var state`.
///
/// ## The C-callback interop
/// `IOPSNotificationCreateRunLoopSource` takes a plain C function pointer
/// (`IOPowerSourceCallbackType == @convention(c) (UnsafeMutableRawPointer?)
/// -> Void`) as its callback. A `@convention(c)` closure CANNOT capture any
/// Swift context — no `self`, no captured locals — so there is no way to get
/// back to this instance from inside it except the classic `Unmanaged`
/// dance: pass `Unmanaged.passUnretained(self).toOpaque()` in as the
/// `context` argument at registration time, and reconstruct `self` from that
/// same pointer inside the callback via
/// `Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()`.
/// This mirrors `HotkeyManager.installEventHandlerIfNeeded()`'s Carbon
/// callback — the one other plain-C callback in this codebase — except this
/// one uses `MainActor.assumeIsolated` instead of `DispatchQueue.main.async`
/// to get back onto the main actor (see below for why that's safe here
/// specifically). `passUnretained` (not `passRetained`) because `stop()`
/// always removes the run-loop source before this object could be
/// deallocated while still registered — there is no ownership cycle to
/// balance with a matching `release()`.
///
/// The callback fires on whatever run loop the source was added to via
/// `CFRunLoopAddSource` — IOKit itself makes no thread guarantee here, it is
/// entirely this class's own choice of run loop. `start()` always adds the
/// source to `CFRunLoopGetMain()`, so the callback is guaranteed to run
/// synchronously on the main thread; that guarantee is what makes
/// `MainActor.assumeIsolated` a true assertion rather than an optimistic
/// guess — if a future change ever added the source to a different run loop,
/// the assertion inside the callback would trap immediately instead of
/// silently racing with the rest of this `@MainActor` class.
@MainActor
final class PowerMonitor {
    let events = PassthroughSubject<PowerEvent, Never>()

    /// Fires below this percent while unplugged (and re-arms above
    /// `lowBatteryRearmThreshold`) — see `lowBatteryEvent`'s doc comment for
    /// the full hysteresis.
    private static let lowBatteryThreshold = 20
    private static let lowBatteryRearmThreshold = 25

    private var runLoopSource: CFRunLoopSource?
    private var previousState: PowerState?
    /// The one bit of memory behind the low-battery hysteresis — `true`
    /// means the next qualifying crossing is allowed to fire.
    private var lowBatteryArmed = true

    /// Installs the IOKit run-loop source and takes an immediate first
    /// reading. No-op if already started. Must be called on the main actor
    /// (guaranteed — this whole class is `@MainActor`) since it adds the
    /// source to the *main* run loop; see the type's doc comment.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            // Safe (not just hopeful): `start()` only ever adds this source
            // to `CFRunLoopGetMain()`, so this callback always fires
            // synchronously on the main thread. See the type doc comment.
            MainActor.assumeIsolated {
                monitor.refresh()
            }
        }, context)?.takeRetainedValue() else {
            powerLog.error("Failed to create IOKit power-source run loop source")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        refresh()
    }

    /// Tears the run-loop source down and forgets the last-seen state, so a
    /// later `start()` begins with a clean baseline (a stale `previousState`
    /// diffed against a fresh first read could otherwise fire a bogus event
    /// for a transition that happened entirely while stopped).
    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.runLoopSource = nil
        previousState = nil
    }

    deinit {
        // `CFRunLoopRemoveSource` is a plain C function taking the opaque
        // source/run-loop tokens, not a call on `self` — safe to call from
        // `deinit` the same way `HotkeyManager.deinit` calls
        // `RemoveEventHandler` directly.
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    // MARK: - Reading + diffing

    private func refresh() {
        guard let snapshot = Self.readPowerState() else { return }
        let previous = previousState
        previousState = snapshot

        // First read after (re)starting: nothing to diff against yet, so no
        // event — only a real transition between two observed snapshots
        // counts.
        guard let previous else { return }

        if let plug = Self.plugEvent(previous: previous, current: snapshot) {
            events.send(plug)
        }
        if let low = Self.lowBatteryEvent(previous: previous, current: snapshot, armed: &lowBatteryArmed) {
            events.send(low)
        }
    }

    /// Reads the current state straight from IOKit's power-source APIs.
    /// `nil` when there is no power source to report on at all (some Mac
    /// desktops report none), which `refresh()` treats as "nothing to
    /// update" rather than clearing `previousState`.
    private static func readPowerState() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
        // `kIOPSCurrentCapacityKey` is already a 0-100 percentage on modern
        // macOS, but deriving it from current/max (when max isn't the
        // trivial 100) is what the API has always documented as the correct
        // way to compute "percent" — cheap insurance against a source that
        // reports some other scale.
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let onACPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        return PowerState(percent: percent, isCharging: isCharging, onACPower: onACPower)
    }

    // MARK: - Pure event derivation (testable without a real IOKit source)

    /// A change in `onACPower` between two consecutive snapshots — the
    /// entire plug/unplug detection. Extracted as a pure function (rather
    /// than inlined in `refresh()`) so `--selftest` can drive every
    /// transition directly.
    static func plugEvent(previous: PowerState, current: PowerState) -> PowerEvent? {
        guard previous.onACPower != current.onACPower else { return nil }
        return current.onACPower ? .pluggedIn(percent: current.percent) : .unplugged(percent: current.percent)
    }

    /// The low-battery hysteresis: fires `.lowBattery` at most once per
    /// crossing below `lowBatteryThreshold` while unplugged, then stays
    /// silent (`armed == false`) through every subsequent tick still under
    /// that line — without this, a battery ticking 19%, 18%, 17%... would
    /// re-post a live activity on every single percent change. Re-arms only
    /// once the percent recovers above `lowBatteryRearmThreshold`, a
    /// *different, higher* line than the one that fired — that gap (20% to
    /// fire, 25% to re-arm) is deliberate: without it, a battery bouncing
    /// across a single boundary (a noisy read, a momentary charge blip)
    /// could still machine-gun-refire right at the edge. Plugging in also
    /// re-arms unconditionally (regardless of percent) since a fresh unplug
    /// afterward is a new, distinct low-battery situation that deserves its
    /// own notice.
    ///
    /// `armed` is `inout` — the caller (`refresh()`) owns the single
    /// persistent bit across calls; this function only reads/writes it, so
    /// `--selftest` can drive the same state machine with a plain local
    /// `var` and no `PowerMonitor` instance at all. `previous` isn't itself
    /// consulted below — `armed` already captures everything this rule needs
    /// to know about history, more precisely than re-deriving it from a raw
    /// percent comparison would — but it's kept in the signature to mirror
    /// `plugEvent`'s shape and leave room for a future rule that does want
    /// the prior sample (e.g. reacting to a suspiciously large single-tick
    /// drop).
    ///
    /// The re-arm crossing (climbing back above `lowBatteryRearmThreshold`
    /// while still unplugged) also emits `.batteryRecovered` — but only when
    /// `armed` was `false` going in, i.e. a `.lowBattery` had actually fired
    /// and is presumably still showing as a sticky live activity. Without
    /// that guard, every ordinary tick above the re-arm line (the overwhelming
    /// common case — most of a discharge cycle never gets near 20%) would
    /// emit a spurious "recovered" event with nothing to recover from. The
    /// plugged-in re-arm path deliberately does NOT emit `.batteryRecovered`:
    /// `.pluggedIn` already carries its own replacement activity of the same
    /// `.battery` kind (see `NotchActivityRouter`), so there's nothing extra
    /// to dismiss there.
    static func lowBatteryEvent(previous: PowerState, current: PowerState, armed: inout Bool) -> PowerEvent? {
        guard !current.onACPower else {
            armed = true
            return nil
        }
        guard current.percent <= lowBatteryRearmThreshold else {
            let recovering = !armed
            armed = true
            return recovering ? .batteryRecovered(percent: current.percent) : nil
        }
        guard armed, current.percent <= lowBatteryThreshold else { return nil }
        armed = false
        return .lowBattery(percent: current.percent)
    }
}
