import Foundation
import Combine

/// Single home for every producer that turns a headless service's events
/// into `LiveActivity` posts.
///
/// Before M3, `AppDelegate` accreted this kind of thing ad hoc: the
/// menu-bar-overflow warning was wired as a bespoke Combine sink directly on
/// `AppDelegate` (`observeNotchOverflowActivity` + its own cancellable). The
/// M1 code review flagged that shape as something that would only get worse
/// as more producers (battery, Bluetooth, and eventually HUD/timers) were
/// added — each one another sink, another cancellable, another few lines of
/// `AppDelegate` that have nothing to do with being an `NSApplicationDelegate`.
/// This type is the fix: it owns *every* activity producer (menu-bar
/// overflow, moved here from `AppDelegate`; battery and Bluetooth, new in
/// M3), and `AppDelegate` now only constructs it and wires the one thing
/// that's legitimately app-specific — routing a *tap* on a live activity's
/// wings into Arrange Mode (`NotchWindowController.onActivityTap`), which
/// stays in `AppDelegate` because it's UI-input routing, not activity
/// production.
///
/// Also owns the `PowerMonitor`/`BluetoothMonitor` service instances
/// outright (rather than `AppDelegate` holding them and merely handing this
/// their `events` publishers) — this router is the only consumer either
/// monitor has, so there is no reason for `AppDelegate` to reference them at
/// all. Both are injectable (default-constructed) purely so `--selftest` can
/// substitute instances and feed synthetic events through `.events` without
/// touching real IOKit/IOBluetooth state.
@MainActor
final class NotchActivityRouter {
    private let activities: LiveActivityCenter
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let power: PowerMonitor
    private let bluetooth: BluetoothMonitor
    /// Gates every real `power.start()`/`bluetooth.start()` call (see
    /// `applyMonitorState`) — `false` only for `--selftest`, which feeds
    /// synthetic events straight through `power.events`/`bluetooth.events`
    /// (wired unconditionally by `observePower`/`observeBluetooth` above) and
    /// must never let this router's normal settings-driven lifecycle touch
    /// real IOKit/IOBluetooth on a headless CI runner.
    private let startsMonitors: Bool
    /// Whether there's currently anywhere to actually show a wing — wired by
    /// the app to `NotchWindowController.isPresenting`. Checked alongside the
    /// notch/activity settings toggles in `applyMonitorState`: running the
    /// battery/Bluetooth monitors while no notched panel is presenting (an
    /// external-only clamshell setup, or the notch's screen momentarily lost)
    /// burns IOKit/IOBluetooth resources for activities that can never
    /// render. Defaults to `{ true }` so call sites that don't care about
    /// presentation (like `--selftest`) don't have to wire anything.
    private let isPresentationAvailable: () -> Bool

    private var cancellables = Set<AnyCancellable>()

    // `power`/`bluetooth` take optionals defaulting to `nil` — rather than
    // defaulting directly to `PowerMonitor()`/`BluetoothMonitor()` — because
    // default-argument expressions are evaluated in a nonisolated context,
    // and both types' initializers are `@MainActor`-isolated. Constructing
    // them here in the init body (which *is* MainActor-isolated, since this
    // whole class is) sidesteps that.
    init(activities: LiveActivityCenter,
         settings: SettingsStore,
         arranger: MenuBarArranger,
         power: PowerMonitor? = nil,
         bluetooth: BluetoothMonitor? = nil,
         startsMonitors: Bool = true,
         isPresentationAvailable: @escaping () -> Bool = { true }) {
        self.activities = activities
        self.settings = settings
        self.arranger = arranger
        self.power = power ?? PowerMonitor()
        self.bluetooth = bluetooth ?? BluetoothMonitor()
        self.startsMonitors = startsMonitors
        self.isPresentationAvailable = isPresentationAvailable

        observePower()
        observeBluetooth()
        observeOverflow()
        observeOverflowGating()
        observeMonitorGating()
        applyMonitorState()
    }

    // MARK: - Battery
    //
    // Lifetime design: plug/unplug notices are transient (4s) — routine,
    // glance-and-gone. The low-battery warning is different on purpose: a 4s
    // toast is easy to miss entirely for a warning that actually matters (the
    // M3 review's exact complaint), so it's posted *sticky* (`duration: nil`)
    // and stays up until something explicitly resolves it. Two things do:
    //   1. Plugging in. `.pluggedIn` posts its own (still transient) charging
    //      activity of the same `.battery` kind, and `LiveActivityCenter.post`
    //      already dismisses any existing activity of the kind it's posting
    //      before queuing the replacement — so the sticky warning never
    //      lingers behind the charging notice; no extra dismiss needed there.
    //   2. The percent recovering above the re-arm threshold *without* a plug
    //      event (`.batteryRecovered`, emitted by `PowerMonitor.lowBatteryEvent`
    //      — see its doc comment) — handled below with an explicit
    //      `dismiss(kind: .battery)` since there's no replacement activity to
    //      post in that case, just a stale warning to clear.

    private func observePower() {
        power.events
            .sink { [weak self] event in self?.handlePowerEvent(event) }
            .store(in: &cancellables)
    }

    private func handlePowerEvent(_ event: PowerEvent) {
        guard settings.notchActivityBatteryEnabled else { return }
        switch event {
        case .pluggedIn(let percent):
            activities.post(batteryActivity(percent: percent, charging: true, warning: false))
        case .unplugged(let percent):
            activities.post(batteryActivity(percent: percent, charging: false, warning: false))
        case .lowBattery(let percent):
            activities.post(batteryActivity(percent: percent, charging: false, warning: true))
        case .batteryRecovered:
            activities.dismiss(kind: .battery)
        }
    }

    /// `warning` activities (low battery) are sticky (`duration: nil`); every
    /// other battery activity (plug/unplug) stays transient at 4s — see the
    /// design note above.
    private func batteryActivity(percent: Int, charging: Bool, warning: Bool) -> LiveActivity {
        LiveActivity(kind: .battery,
                     leading: .icon(systemName: Self.batterySymbol(percent: percent, charging: charging)),
                     trailing: .text("\(percent)%"),
                     duration: warning ? nil : 4,
                     priority: 200,
                     tint: warning ? .warning : .normal)
    }

    /// SF Symbols' battery glyphs only ship in 100/75/50/25/0 steps — this
    /// rounds `percent` DOWN to the nearest one (never up: a 74% battery
    /// showing the 75% glyph would visually overstate the charge) and swaps
    /// in the `.bolt` variant while charging, matching how the system's own
    /// menu-bar battery item reads.
    static func batterySymbol(percent: Int, charging: Bool) -> String {
        let clamped = max(0, min(100, percent))
        let step = (clamped / 25) * 25
        let base = "battery.\(step)"
        return charging ? "\(base).bolt" : base
    }

    // MARK: - Bluetooth

    private func observeBluetooth() {
        bluetooth.events
            .sink { [weak self] event in self?.handleBluetoothEvent(event) }
            .store(in: &cancellables)
    }

    private func handleBluetoothEvent(_ event: BluetoothEvent) {
        guard settings.notchActivityBluetoothEnabled else { return }
        switch event {
        case .connected(let name, let batteryPercent, let category):
            let trailing: LiveActivity.Content = batteryPercent.map {
                .iconText(systemName: Self.batterySymbol(percent: $0, charging: false), text: "\($0)%")
            } ?? .text(name)
            activities.post(LiveActivity(kind: .bluetoothDevice,
                                          leading: .icon(systemName: Self.deviceSymbol(name: name, category: category)),
                                          trailing: trailing,
                                          duration: 4,
                                          priority: 100))
        case .disconnected(let name, let category):
            activities.post(LiveActivity(kind: .bluetoothDevice,
                                          leading: .icon(systemName: Self.deviceSymbol(name: name, category: category)),
                                          trailing: .text("Disconnected"),
                                          duration: 4,
                                          priority: 100))
        }
    }

    /// Which SF Symbol reads as "this device." `category` (the device's
    /// IOKit class major, threaded through by `BluetoothMonitor`) does the
    /// coarse audio-vs-HID split; IOBluetooth exposes no further product-line
    /// identifier beyond that and the device's own advertised name, so
    /// picking the specific HID glyph (keyboard / mouse / game controller)
    /// within `.peripheral` is still a name-based best-effort guess. Every
    /// Apple AirPods product name ("AirPods", "AirPods Pro", "AirPods Max",
    /// ...) contains "airpods"; every other audio accessory (or anything
    /// IOKit didn't class as HID either) falls back to a generic headphones
    /// glyph, which still reads correctly for the audio devices
    /// `BluetoothMonitor` actually filters to.
    static func deviceSymbol(name: String, category: BluetoothDeviceCategory) -> String {
        guard category == .peripheral else {
            return name.lowercased().contains("airpods") ? "airpodspro" : "headphones"
        }
        let lower = name.lowercased()
        if lower.contains("mouse") { return "computermouse" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("controller") || lower.contains("gamepad") || lower.contains("joystick") {
            return "gamecontroller"
        }
        // An HID peripheral IOKit classed as such, but whose name doesn't
        // hint at which kind — a generic accessory glyph beats mislabeling it
        // "headphones."
        return "cable.connector"
    }

    // MARK: - Menu-bar overflow (moved from AppDelegate — see type doc comment)

    /// Identical behavior to the pre-M3 `AppDelegate.observeNotchOverflowActivity`:
    /// posts a sticky (`duration: nil`) `.menuBarOverflow` activity while
    /// icons are clipped behind the notch, dismisses it the moment they're
    /// not. Gated on `settings.notchEnabled` (rather than only existing while
    /// enabled, the way the legacy code structured it) since this router — and
    /// its subscription to `arranger` — now lives for the app's whole
    /// lifetime regardless of that setting.
    private func observeOverflow() {
        arranger.$notchOverflow
            .combineLatest(arranger.$overflowIconCount)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self, self.settings.notchEnabled else { return }
                self.applyOverflowState()
            }
            .store(in: &cancellables)
    }

    /// Posts or dismisses `.menuBarOverflow` to match `arranger`'s *current*
    /// overflow snapshot, read directly rather than from whatever values
    /// happened to be threaded through a subscription. Shared by
    /// `observeOverflow()` (fires on a genuine change) and
    /// `observeOverflowGating()` re-enabling the notch (below) — the latter
    /// needs this because `arranger`'s state may not have changed at all
    /// since it was gated off, so `observeOverflow`'s `removeDuplicates`
    /// pipeline would otherwise emit nothing and the warning would just stay
    /// missing until the overflow condition itself next changes.
    private func applyOverflowState() {
        if arranger.notchOverflow {
            activities.post(LiveActivity(
                kind: .menuBarOverflow,
                leading: .icon(systemName: "exclamationmark.triangle.fill"),
                trailing: arranger.overflowIconCount > 0 ? .text("\(arranger.overflowIconCount)") : .none,
                duration: nil,
                priority: 150))
        } else {
            activities.dismiss(kind: .menuBarOverflow)
        }
    }

    /// Mirrors the pre-M3 `AppDelegate.configureNotchOverflowCoexistence`'s
    /// `else` branch on disable: disabling the notch panel leaves no wing
    /// left to show the overflow warning in, so its live activity (if any) is
    /// dismissed immediately rather than waiting for `arranger`'s own state to
    /// happen to change next (which, with the notch disabled, might never
    /// happen again before the panel is re-enabled).
    ///
    /// Also re-syncs on *re*-enable: if the notch is toggled back on while
    /// the menu bar is still overflowing, `arranger`'s published state may
    /// never have changed in between (an unchanging condition doesn't
    /// republish through `observeOverflow`'s deduped pipeline), so the
    /// permanently-subscribed sink would otherwise emit nothing and the
    /// warning would silently stay missing — `applyOverflowState()` re-checks
    /// the live snapshot instead of relying on that subscription to catch it.
    private func observeOverflowGating() {
        settings.$notchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.applyOverflowState()
                } else {
                    self.activities.dismiss(kind: .menuBarOverflow)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitor lifecycle

    /// Re-applies monitor start/stop whenever the notch master switch or
    /// either activity toggle changes. `dropFirst` skips the redundant
    /// initial delivery each of these `@Published` properties makes at
    /// subscription time — `init` already calls `applyMonitorState()` once
    /// directly for that. Passes the emitted tuple straight into
    /// `applyMonitorState` rather than letting it re-read `settings` itself —
    /// this sink already has the exact values that changed in hand.
    private func observeMonitorGating() {
        settings.$notchEnabled
            .combineLatest(settings.$notchActivityBatteryEnabled, settings.$notchActivityBluetoothEnabled)
            .dropFirst()
            .sink { [weak self] notchEnabled, batteryEnabled, bluetoothEnabled in
                self?.applyMonitorState(notchEnabled: notchEnabled,
                                        batteryEnabled: batteryEnabled,
                                        bluetoothEnabled: bluetoothEnabled)
            }
            .store(in: &cancellables)
    }

    /// The battery/Bluetooth monitors only run when their own settings
    /// toggle is on *and* the notch panel itself is enabled *and* there's
    /// somewhere to actually show a wing (`isPresentationAvailable()`) — an
    /// external-only clamshell setup, or a moment where the notch's screen
    /// has been lost, leaves nowhere for either activity to render, so idling
    /// the monitors there saves the IOKit run-loop source / IOBluetooth
    /// notifications for nothing. `start()`/`stop()` on both monitors are
    /// no-ops when already in the requested state, so this can be called
    /// freely on every settings tick (or presentation change) without
    /// worrying about double-registration.
    ///
    /// The three `Bool?` parameters default to `nil`, in which case the
    /// current value is read straight from `settings` — used by every caller
    /// that isn't reacting to one specific emitted change (`init`'s initial
    /// call, and the presentation-change callback wired in by the app, which
    /// has no settings tuple of its own to hand in). `observeMonitorGating`'s
    /// sink is the one caller that always supplies all three explicitly.
    ///
    /// Also gated on `startsMonitors` — `false` only for `--selftest` (see
    /// its doc comment) — so a headless test run never touches real
    /// IOKit/IOBluetooth state no matter how many settings toggles it flips.
    private func applyMonitorState(notchEnabled: Bool? = nil, batteryEnabled: Bool? = nil, bluetoothEnabled: Bool? = nil) {
        guard startsMonitors else { return }
        let notchOn = (notchEnabled ?? settings.notchEnabled) && isPresentationAvailable()

        if notchOn && (batteryEnabled ?? settings.notchActivityBatteryEnabled) {
            power.start()
        } else {
            power.stop()
            activities.dismiss(kind: .battery)
        }

        if notchOn && (bluetoothEnabled ?? settings.notchActivityBluetoothEnabled) {
            bluetooth.start()
        } else {
            bluetooth.stop()
            activities.dismiss(kind: .bluetoothDevice)
        }
    }

    /// Re-syncs the monitor start/stop decision after something *outside*
    /// the settings toggles changed whether there's anywhere to present a
    /// wing — specifically, `NotchWindowController.onPresentationChanged`
    /// firing on a screen-configuration change (external display connect,
    /// clamshell open/close). Public because that wiring lives in the app
    /// layer (`AppDelegate`), not this file — see `isPresentationAvailable`'s
    /// doc comment.
    func presentationDidChange() {
        applyMonitorState()
    }
}
