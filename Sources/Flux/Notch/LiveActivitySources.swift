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
    /// Shared with `CalendarWidget` — unlike `power`/`bluetooth` (whose only
    /// consumer is this router), this instance is also the Calendar widget's
    /// own data source, so it's injected rather than default-constructed
    /// here. This router is now the SOLE caller of `calendar.start()`/
    /// `.stop()` — see `CalendarService`'s own doc comment on that ownership
    /// change, and `calendarServiceShouldRun` below for the derivation.
    private let calendar: CalendarService
    /// Read-only here — this router only ever calls `refresh`/reads
    /// `statuses`; `request`/`openSystemSettings` are Settings-UI actions the
    /// Calendar widget itself owns.
    private let permissions: PermissionCenter
    /// The notch's state machine — read directly (`viewModel.state`) rather
    /// than through a bespoke closure, so `calendarServiceShouldRun` always
    /// sees the live value, and `observeNotchState()` can subscribe to
    /// `viewModel.$state` for change notifications the same way
    /// `observeCalendar()` subscribes to `calendar.$upcoming`.
    private let viewModel: NotchViewModel
    /// Gates every real `power.start()`/`bluetooth.start()` call (see
    /// `applyMonitorState`) — `false` only for `--selftest`, which feeds
    /// synthetic events straight through `power.events`/`bluetooth.events`
    /// (wired unconditionally by `observePower`/`observeBluetooth` above) and
    /// must never let this router's normal settings-driven lifecycle touch
    /// real IOKit/IOBluetooth on a headless CI runner.
    private let startsMonitors: Bool
    /// The latest value delivered by the injected `presentation` publisher —
    /// whether there's currently anywhere to actually show a wing. Cached
    /// here (rather than re-read on demand) because `applyMonitorState` is
    /// also invoked from sinks that have nothing to do with presentation
    /// (settings, permission) and need the most recently observed value.
    private var isPresenting = false

    private var cancellables = Set<AnyCancellable>()

    // `power`/`bluetooth` take optionals defaulting to `nil` — rather than
    // defaulting directly to `PowerMonitor()`/`BluetoothMonitor()` — because
    // default-argument expressions are evaluated in a nonisolated context,
    // and both types' initializers are `@MainActor`-isolated. Constructing
    // them here in the init body (which *is* MainActor-isolated, since this
    // whole class is) sidesteps that.
    //
    // `presentation` replaces the old `isPresentationAvailable`/
    // `isCalendarWidgetPresented` bespoke closures (see the M4 code-review
    // fix): a small, directly-injectable publisher — `NotchWindowController`
    // wires its own `$isPresenting` in production — rather than the whole
    // concrete `NotchWindowController`, so `--selftest` can drive presentation
    // changes with a plain `CurrentValueSubject`, with no real NSScreen/panel
    // behind it at all. Defaults to `Just(true)` so callers that don't care
    // (most of `--selftest`) don't have to wire anything.
    init(activities: LiveActivityCenter,
         settings: SettingsStore,
         arranger: MenuBarArranger,
         calendar: CalendarService,
         permissions: PermissionCenter,
         viewModel: NotchViewModel,
         power: PowerMonitor? = nil,
         bluetooth: BluetoothMonitor? = nil,
         startsMonitors: Bool = true,
         presentation: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher()) {
        self.activities = activities
        self.settings = settings
        self.arranger = arranger
        self.calendar = calendar
        self.permissions = permissions
        self.viewModel = viewModel
        self.power = power ?? PowerMonitor()
        self.bluetooth = bluetooth ?? BluetoothMonitor()
        self.startsMonitors = startsMonitors

        observePower()
        observeBluetooth()
        observeOverflow()
        observeOverflowGating()
        observeCalendar()
        observeMonitorGating()
        observeNotchState()
        observePresentation(presentation)
        applyMonitorState()
    }

    deinit {
        calendarThresholdTask?.cancel()
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

    // MARK: - Calendar (M4: event-soon activity)

    /// One cancellable deadline task, armed for the next moment the
    /// event-soon decision could change (either a threshold crossing or an
    /// event's own start passing) — see `scheduleNextCalendarBoundary`'s doc
    /// comment. Mirrors `LiveActivityCenter.expiryTasks`'s single-deadline
    /// shape: no repeating timer anywhere in this pipeline.
    private var calendarThresholdTask: Task<Void, Never>?

    private func observeCalendar() {
        calendar.$upcoming
            .sink { [weak self] _ in self?.recomputeCalendarActivity() }
            .store(in: &cancellables)
    }

    /// Re-evaluates the event-soon `LiveActivity` against the current
    /// `upcoming` list and gating (settings toggle + calendar permission),
    /// then arms the next boundary task. Called whenever `upcoming` changes,
    /// whenever the gating settings change (`observeMonitorGating`, extended
    /// below to include the calendar toggle), and by the boundary task
    /// itself once its deadline arrives.
    private func recomputeCalendarActivity() {
        calendarThresholdTask?.cancel()
        calendarThresholdTask = nil

        guard settings.notchActivityCalendarEventEnabled,
              permissions.statuses[.calendar] == .granted
        else {
            activities.dismiss(kind: .calendarEvent)
            return
        }

        let now = Date()
        if let activity = Self.calendarEventSoonActivity(events: calendar.upcoming, now: now) {
            activities.post(activity)
        } else {
            activities.dismiss(kind: .calendarEvent)
        }
        scheduleNextCalendarBoundary(now: now)
    }

    /// No repeating timer: computes the single next instant this decision
    /// could flip and sleeps exactly until then before re-evaluating.
    /// Cancelled/replaced on every recompute (including by itself, at the top
    /// of `recomputeCalendarActivity`) so only the most recently scheduled
    /// boundary can ever fire, the same pattern `NotchRootView`'s
    /// `interactiveRectSettleTask` and `LiveActivityCenter`'s expiry tasks use.
    /// The actual "when" is `nextCalendarBoundary` — split out as a pure
    /// function below so `--selftest` can verify the countdown-tick math
    /// directly.
    private func scheduleNextCalendarBoundary(now: Date) {
        guard let next = Self.nextCalendarBoundary(events: calendar.upcoming, now: now) else { return }

        calendarThresholdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.recomputeCalendarActivity()
        }
    }

    /// How far ahead of an event's start the sticky wing appears.
    static let calendarSoonThreshold: TimeInterval = 10 * 60

    /// The next instant `calendarEventSoonActivity`'s decision (or its
    /// displayed text) could change:
    /// - an event crossing *into* the 10-minute window (`start - threshold`),
    /// - the soonest-showing event's own start passing (so the wing comes
    ///   down the moment it's no longer "soon," not up to a full tick late),
    /// - AND — the code-review fix this adds — the next whole-minute tick
    ///   while an event is currently inside the window. Without this last
    ///   case, the earlier two boundaries alone could leave the wing's
    ///   "in Nm" text frozen at whatever `now` was at the last recompute for
    ///   up to the full 10 minutes (nothing else would ever wake the router
    ///   up to refresh the text as the minutes actually tick down).
    /// All-day events are excluded — their `start` is local midnight, which
    /// is never a meaningful "starting soon" boundary (or countdown) to wake
    /// up for.
    static func nextCalendarBoundary(events: [CalendarEvent], now: Date) -> Date? {
        let relevant = events.filter { !$0.isAllDay }
        var boundaries = relevant
            .flatMap { [$0.start.addingTimeInterval(-calendarSoonThreshold), $0.start] }
            .filter { $0 > now }
        if calendarEventSoonActivity(events: relevant, now: now) != nil {
            boundaries.append(nextMinuteBoundary(after: now))
        }
        return boundaries.min()
    }

    /// The next whole-minute wall-clock instant strictly after `now` — e.g.
    /// 10:32:47 → 10:33:00. Used only to keep the event-soon wing's "in Nm"
    /// text ticking down minute-by-minute; always strictly greater than
    /// `now`, even when `now` itself already lands exactly on a minute
    /// boundary, since the scheduled task must sleep a positive duration.
    static func nextMinuteBoundary(after now: Date) -> Date {
        let epoch = now.timeIntervalSinceReferenceDate
        let nextMinuteEpoch = (epoch / 60).rounded(.down) * 60 + 60
        return Date(timeIntervalSinceReferenceDate: nextMinuteEpoch)
    }

    /// Pure core of the event-soon decision: the earliest not-yet-started,
    /// non-all-day event whose start falls within `calendarSoonThreshold` of
    /// `now` becomes a sticky (`duration: nil`, dismissed explicitly once
    /// it's no longer soon) wing; anything else yields `nil` so the caller
    /// dismisses instead. All-day events are excluded — their `start` is
    /// local midnight, so treating that as "starting soon" would fire a
    /// meaningless alert at every midnight rollover; they still show in the
    /// widget's own agenda (`CalendarService.groupByDay` is untouched).
    /// Priority 120 sits between menu-bar overflow (150, a layout problem)
    /// and Bluetooth (100, a routine connect/disconnect blip) — an upcoming
    /// event is more actionable than "a device connected" but isn't the
    /// "something needs your attention right now" tier `.warning`/300 HUD
    /// activities occupy. The trailing text is built by
    /// `CalendarService.relativeStartPhrase` — the same shared helper
    /// `CalendarService.nextEventLine` uses — rather than a second, separate
    /// minutes/hours computation living here.
    static func calendarEventSoonActivity(events: [CalendarEvent], now: Date) -> LiveActivity? {
        guard let next = events
            .filter({ !$0.isAllDay && $0.start >= now && $0.start.timeIntervalSince(now) <= calendarSoonThreshold })
            .min(by: { $0.start < $1.start })
        else { return nil }

        return LiveActivity(kind: .calendarEvent,
                             leading: .icon(systemName: "calendar"),
                             trailing: .text(CalendarService.relativeStartPhrase(title: next.title, start: next.start, now: now)),
                             duration: nil,
                             priority: 120)
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
            .combineLatest(settings.$notchActivityBatteryEnabled, settings.$notchActivityBluetoothEnabled,
                           settings.$notchActivityCalendarEventEnabled)
            .dropFirst()
            .sink { [weak self] notchEnabled, batteryEnabled, bluetoothEnabled, calendarEnabled in
                self?.applyMonitorState(notchEnabled: notchEnabled,
                                        batteryEnabled: batteryEnabled,
                                        bluetoothEnabled: bluetoothEnabled,
                                        calendarEnabled: calendarEnabled)
                // The settings toggle also directly gates whether the
                // event-soon activity itself may show — re-evaluate it here
                // too, not just the underlying service's start/stop, so
                // switching the toggle off dismisses an already-showing wing
                // immediately rather than waiting for `upcoming` to next
                // change.
                self?.recomputeCalendarActivity()
            }
            .store(in: &cancellables)

        // Permission can change independently of every settings toggle above
        // (the user grants/revokes Calendar access in System Settings) —
        // `PermissionCenter.refresh` picks that up on app activation, and
        // this re-applies both the service's start/stop and the activity's
        // own gating whenever it does. This is also the "grant-while-open"
        // fix: if the Calendar widget happens to be the one currently
        // expanded when the grant lands, `calendarServiceShouldRun` sees
        // both `permissionGranted` and the widget-open condition true in the
        // same tick and starts the service right here — no separate
        // widget-side `willPresent` re-check needed.
        permissions.$statuses
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyMonitorState()
                self?.recomputeCalendarActivity()
            }
            .store(in: &cancellables)
    }

    /// Re-applies `applyMonitorState` whenever the notch's own state machine
    /// changes — specifically so the Calendar widget becoming (or stopping
    /// being) the currently-`.expanded` widget is re-evaluated the same tick,
    /// which `calendarServiceShouldRun` needs. The initial delivery every
    /// `@Published` makes at subscription time is harmless here (unlike the
    /// `dropFirst()` sinks above): `applyMonitorState` is idempotent, and this
    /// runs before `init`'s own explicit final call anyway.
    private func observeNotchState() {
        viewModel.$state
            .sink { [weak self] _ in self?.applyMonitorState() }
            .store(in: &cancellables)
    }

    /// Caches the injected `presentation` publisher's latest value into
    /// `isPresenting` and re-applies both the monitor state and the
    /// calendar-event activity gating whenever it changes — this is the
    /// "screen-disappear stops the service" fix: `NotchWindowController`
    /// wires its own `$isPresenting` in production, so losing the notch's
    /// screen (external-only clamshell, lid closed) or disabling the notch
    /// panel entirely flows straight through to `calendarServiceShouldRun`
    /// seeing `notchPresenting == false`, without any bespoke closure. The
    /// first delivery (every `@Published`/`CurrentValueSubject`-backed
    /// publisher emits synchronously on subscribe) is what seeds
    /// `isPresenting` correctly before `init`'s own final `applyMonitorState()`
    /// call — deliberately not `dropFirst()`, unlike `observeMonitorGating`'s
    /// settings sinks, which don't need a value seeded this way since
    /// `settings` itself is read directly wherever it matters.
    private func observePresentation(_ presentation: AnyPublisher<Bool, Never>) {
        presentation
            .sink { [weak self] value in
                guard let self else { return }
                self.isPresenting = value
                self.applyMonitorState()
                self.recomputeCalendarActivity()
            }
            .store(in: &cancellables)
    }

    /// The battery/Bluetooth monitors only run when their own settings
    /// toggle is on *and* the notch panel itself is enabled *and* there's
    /// somewhere to actually show a wing (`isPresenting`) — an external-only
    /// clamshell setup, or a moment where the notch's screen has been lost,
    /// leaves nowhere for either activity to render, so idling the monitors
    /// there saves the IOKit run-loop source / IOBluetooth notifications for
    /// nothing. `start()`/`stop()` on both monitors are no-ops when already
    /// in the requested state, so this can be called freely on every
    /// settings tick (or presentation/state change) without worrying about
    /// double-registration.
    ///
    /// The four `Bool?` parameters default to `nil`, in which case the
    /// current value is read straight from `settings` — used by every caller
    /// that isn't reacting to one specific emitted settings change (`init`'s
    /// initial call, and every non-settings sink: presentation, notch state,
    /// permission). `observeMonitorGating`'s sink is the one caller that
    /// always supplies all four explicitly.
    ///
    /// Also gated on `startsMonitors` — `false` only for `--selftest` (see
    /// its doc comment) — so a headless test run never touches real
    /// IOKit/IOBluetooth/EventKit state no matter how many settings toggles
    /// it flips.
    ///
    /// Calendar's `start()`/`stop()` here is now this router's ONLY vote —
    /// see `calendarServiceShouldRun` and `CalendarService`'s own doc comment
    /// on the ownership fix this replaced (the old
    /// `isCalendarWidgetPresented()` closure this router used to defer to).
    private func applyMonitorState(notchEnabled: Bool? = nil, batteryEnabled: Bool? = nil,
                                    bluetoothEnabled: Bool? = nil, calendarEnabled: Bool? = nil) {
        guard startsMonitors else { return }
        let notchOn = (notchEnabled ?? settings.notchEnabled) && isPresenting

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

        let shouldRunCalendar = Self.calendarServiceShouldRun(
            permissionGranted: permissions.statuses[.calendar] == .granted,
            notchPresenting: isPresenting,
            widgetEnabled: settings.notchCalendarEnabled,
            state: viewModel.state,
            activityToggleOn: calendarEnabled ?? settings.notchActivityCalendarEventEnabled)
        if shouldRunCalendar {
            calendar.start()
        } else {
            calendar.stop()
        }
    }

    /// Pure core of "should the shared `CalendarService` be running right
    /// now" — the M4 code-review fix that replaced the old
    /// `isCalendarWidgetPresented`/`isPresentationAvailable` closure pair
    /// (see `CalendarService`'s own doc comment for the bug that shape let
    /// through: a permission grant while the widget was open never started
    /// the service, because neither owner's own start condition was
    /// individually true at that instant).
    ///
    /// The service only ever needs to run for one of two reasons — the
    /// Calendar widget itself is the one currently expanded (so its agenda
    /// needs live data), or the event-soon activity toggle is on (so a wing
    /// can appear even while the widget itself is closed) — and neither
    /// reason matters without BOTH calendar permission and somewhere to
    /// actually present: a denied permission has nothing to show, and a
    /// service running with the notch's screen gone (or the panel disabled)
    /// has nowhere to render either the widget or the wing.
    static func calendarServiceShouldRun(permissionGranted: Bool, notchPresenting: Bool,
                                          widgetEnabled: Bool, state: NotchState,
                                          activityToggleOn: Bool) -> Bool {
        guard permissionGranted, notchPresenting else { return false }
        let widgetOpen = widgetEnabled && state == .expanded(.calendar)
        return widgetOpen || activityToggleOn
    }
}
