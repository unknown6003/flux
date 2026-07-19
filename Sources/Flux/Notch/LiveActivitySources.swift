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
         bluetooth: BluetoothMonitor? = nil) {
        self.activities = activities
        self.settings = settings
        self.arranger = arranger
        self.power = power ?? PowerMonitor()
        self.bluetooth = bluetooth ?? BluetoothMonitor()

        observePower()
        observeBluetooth()
        observeOverflow()
        observeOverflowGating()
        observeMonitorGating()
        applyMonitorState()
    }

    // MARK: - Battery

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
        }
    }

    private func batteryActivity(percent: Int, charging: Bool, warning: Bool) -> LiveActivity {
        LiveActivity(kind: .battery,
                     leading: .icon(systemName: Self.batterySymbol(percent: percent, charging: charging)),
                     trailing: .text("\(percent)%"),
                     duration: 4,
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
        case .connected(let name, let batteryPercent):
            let trailing: LiveActivity.Content = batteryPercent.map {
                .iconText(systemName: "battery.100", text: "\($0)%")
            } ?? .text(name)
            activities.post(LiveActivity(kind: .bluetoothDevice,
                                          leading: .icon(systemName: Self.deviceSymbol(name: name)),
                                          trailing: trailing,
                                          duration: 4,
                                          priority: 100))
        case .disconnected(let name):
            activities.post(LiveActivity(kind: .bluetoothDevice,
                                          leading: .icon(systemName: Self.deviceSymbol(name: name)),
                                          trailing: .text("Disconnected"),
                                          duration: 4,
                                          priority: 100))
        }
    }

    /// Name-based heuristic for which SF Symbol reads as "this device" —
    /// IOBluetooth exposes no product-line identifier beyond the device's
    /// own advertised name, so this is inherently best-effort. Every Apple
    /// AirPods product name ("AirPods", "AirPods Pro", "AirPods Max", ...)
    /// contains "airpods"; everything else falls back to a generic
    /// headphones glyph, which still reads correctly for the audio/HID-only
    /// devices `BluetoothMonitor` filters to in the first place.
    static func deviceSymbol(name: String) -> String {
        name.lowercased().contains("airpods") ? "airpodspro" : "headphones"
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
            .sink { [weak self] overflowing, count in
                guard let self, self.settings.notchEnabled else { return }
                if overflowing {
                    self.activities.post(LiveActivity(
                        kind: .menuBarOverflow,
                        leading: .icon(systemName: "exclamationmark.triangle.fill"),
                        trailing: count > 0 ? .text("\(count)") : .none,
                        duration: nil,
                        priority: 150))
                } else {
                    self.activities.dismiss(kind: .menuBarOverflow)
                }
            }
            .store(in: &cancellables)
    }

    /// Mirrors the pre-M3 `AppDelegate.configureNotchOverflowCoexistence`'s
    /// `else` branch: disabling the notch panel leaves no wing left to show
    /// the overflow warning in, so its live activity (if any) is dismissed
    /// immediately rather than waiting for `arranger`'s own state to happen
    /// to change next (which, with the notch disabled, might never happen
    /// again before the panel is re-enabled).
    private func observeOverflowGating() {
        settings.$notchEnabled
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.activities.dismiss(kind: .menuBarOverflow) }
            .store(in: &cancellables)
    }

    // MARK: - Monitor lifecycle

    /// Re-applies monitor start/stop whenever the notch master switch or
    /// either activity toggle changes. `dropFirst` skips the redundant
    /// initial delivery each of these `@Published` properties makes at
    /// subscription time — `init` already calls `applyMonitorState()` once
    /// directly for that.
    private func observeMonitorGating() {
        settings.$notchEnabled
            .combineLatest(settings.$notchActivityBatteryEnabled, settings.$notchActivityBluetoothEnabled)
            .dropFirst()
            .sink { [weak self] _ in self?.applyMonitorState() }
            .store(in: &cancellables)
    }

    /// The battery/Bluetooth monitors only run when their own settings
    /// toggle is on *and* the notch panel itself is enabled — there is
    /// nowhere to show their wings otherwise, so idling them saves the
    /// IOKit run-loop source / IOBluetooth notifications for nothing.
    /// `start()`/`stop()` on both monitors are no-ops when already in the
    /// requested state, so this can be called freely on every settings tick
    /// without worrying about double-registration.
    private func applyMonitorState() {
        let notchOn = settings.notchEnabled

        if notchOn && settings.notchActivityBatteryEnabled {
            power.start()
        } else {
            power.stop()
            activities.dismiss(kind: .battery)
        }

        if notchOn && settings.notchActivityBluetoothEnabled {
            bluetooth.start()
        } else {
            bluetooth.stop()
            activities.dismiss(kind: .bluetoothDevice)
        }
    }
}
