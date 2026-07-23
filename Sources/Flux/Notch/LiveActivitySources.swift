import AppKit
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
/// Also owns the `PowerMonitor`/`DeviceMonitor` service instances
/// outright (rather than `AppDelegate` holding them and merely handing this
/// their `events` publishers) — this router is the only consumer either
/// monitor has, so there is no reason for `AppDelegate` to reference them at
/// all. Both are injectable (default-constructed) purely so `--selftest` can
/// substitute instances and feed synthetic events through `.events` without
/// touching real IOKit/CoreAudio state.
@MainActor
final class NotchActivityRouter {
    private let activities: LiveActivityCenter
    private let settings: SettingsStore
    private let arranger: MenuBarArranger
    private let power: PowerMonitor
    private let bluetooth: DeviceMonitor
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
    /// M6: shared with `TimersWidget` — like `calendar`, this router isn't
    /// the countdown machinery's only consumer, so it's injected rather than
    /// default-constructed. Unlike `calendar`, this router never calls
    /// `start()`/`stop()` on it: `TimerService` has no such lifecycle at all
    /// (see its own doc comment — a single cancellable boundary `Task`, never
    /// a repeating timer, so there's nothing to gate on presentation the way
    /// Calendar's EventKit fetch needs to be). This router only turns its
    /// `completions` events and live `timers` into `.timer` live-activity
    /// wings.
    private let timers: TimerService
    /// The notch's state machine — read directly (`viewModel.state`) rather
    /// than through a bespoke closure, so `calendarServiceShouldRun` always
    /// sees the live value, and `observeNotchState()` can subscribe to
    /// `viewModel.$state` for change notifications the same way
    /// `observeCalendar()` subscribes to `calendar.$upcoming`.
    private let viewModel: NotchViewModel
    /// M5: the CoreAudio-backed observe-mode volume source. Owned outright,
    /// like `power`/`bluetooth` — this router is its only consumer.
    private let volume: VolumeMonitor
    /// Gates every real `power.start()`/`bluetooth.start()`/`volume.start()`
    /// call (see `applyMonitorState`/`applyHUDState`) — `false` only for
    /// `--selftest`, which feeds synthetic events straight through
    /// `power.events`/`bluetooth.events`/`volume.events` (wired
    /// unconditionally by `observePower`/`observeBluetooth`/`observeVolume`
    /// above) and must never let this router's normal settings-driven
    /// lifecycle touch real IOKit/CoreAudio on a headless CI runner.
    private let startsMonitors: Bool
    /// The latest value delivered by the injected `presentation` publisher —
    /// whether there's currently anywhere to actually show a wing. Cached
    /// here (rather than re-read on demand) because `applyMonitorState` is
    /// also invoked from sinks that have nothing to do with presentation
    /// (settings, permission) and need the most recently observed value.
    private var isPresenting = false

    private var cancellables = Set<AnyCancellable>()

    // `power`/`bluetooth`/`volume` take optionals defaulting to `nil` —
    // rather than defaulting directly to
    // `PowerMonitor()`/`DeviceMonitor()`/etc. — because default-argument
    // expressions are evaluated in a nonisolated context, and every one of
    // these types' initializers is `@MainActor`-isolated. Constructing them
    // here in the init body (which *is* MainActor-isolated, since this whole
    // class is) sidesteps that.
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
         timers: TimerService,
         power: PowerMonitor? = nil,
         bluetooth: DeviceMonitor? = nil,
         volume: VolumeMonitor? = nil,
         startsMonitors: Bool = true,
         presentation: AnyPublisher<Bool, Never> = Just(true).eraseToAnyPublisher()) {
        self.activities = activities
        self.settings = settings
        self.arranger = arranger
        self.calendar = calendar
        self.permissions = permissions
        self.viewModel = viewModel
        self.timers = timers
        self.power = power ?? PowerMonitor()
        self.bluetooth = bluetooth ?? DeviceMonitor()
        self.volume = volume ?? VolumeMonitor()
        self.startsMonitors = startsMonitors

        observePower()
        observeBluetooth()
        observeVolume()
        observeOverflow()
        observeOverflowGating()
        observeCalendar()
        observeTimers()
        observeMonitorGating()
        observeHUDGating()
        observeTimerGating()
        observeNotchState()
        observeDuoActive()
        observePresentation(presentation)
        applyMonitorState()
        applyHUDState()
        recomputeTimerActivity()
    }

    deinit {
        // `calendarThresholdTask`/`timerRefreshTask` are each a
        // `DeadlineTask` now (see their own doc comments) — its own `deinit`
        // cancels whatever's pending when this router does, so there's
        // nothing left to do here explicitly.
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
    /// showing the 75% glyph would visually overstate the charge).
    ///
    /// Charging is ALWAYS `battery.100.bolt`: SF Symbols ships the `.bolt`
    /// variant only at the 100 step — `battery.75.bolt` etc. simply don't
    /// exist, and `Image(systemName:)` renders NOTHING for an unknown name
    /// (caught via a lock-screen snapshot where a charging wing's icon was
    /// silently blank). The bolt is what communicates "charging"; the percent
    /// lives in the wing's trailing text, so no level information is lost.
    static func batterySymbol(percent: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100.bolt" }
        let clamped = max(0, min(100, percent))
        let step = (clamped / 25) * 25
        return "battery.\(step)"
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

    /// Which SF Symbol reads as "this device." `category` (threaded through by
    /// `DeviceMonitor`, derived from the device's HID usage pairs + name) does
    /// the coarse audio-vs-HID split; there's no further product-line
    /// identifier beyond that and the device's own advertised name, so
    /// picking the specific HID glyph (keyboard / mouse / game controller)
    /// within `.peripheral` is still a name-based best-effort guess. Every
    /// Apple AirPods product name ("AirPods", "AirPods Pro", "AirPods Max",
    /// ...) contains "airpods"; every other audio accessory (or anything
    /// IOKit didn't class as HID either) falls back to a generic headphones
    /// glyph, which still reads correctly for the audio devices
    /// `DeviceMonitor` actually filters to.
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
    /// comment. Backed by the shared `DeadlineTask` helper (see its own doc
    /// comment), which `LiveActivityCenter.expiryTasks` and `TimerService.
    /// boundaryTask` also use: no repeating timer anywhere in this pipeline.
    private let calendarThresholdTask = DeadlineTask()

    private func observeCalendar() {
        // Takes the emitted array directly — not a re-read of `calendar.upcoming`
        // from inside the sink — for the same `@Published`-delivers-from-`willSet`
        // reason `observeTimers()`'s `timers.$timers` sink does (see its own doc
        // comment): a synchronous `calendar.upcoming` read here would see the
        // list from BEFORE this exact update.
        calendar.$upcoming
            .sink { [weak self] events in self?.recomputeCalendarActivity(events: events) }
            .store(in: &cancellables)
    }

    /// Re-evaluates the event-soon `LiveActivity` against the current
    /// `upcoming` list and gating (settings toggle + calendar permission),
    /// then arms the next boundary task. Called whenever `upcoming` changes,
    /// whenever the gating settings change (`observeMonitorGating`, extended
    /// below to include the calendar toggle), and by the boundary task
    /// itself once its deadline arrives.
    ///
    /// `activityToggleOn`/`calendarPermissionGranted`/`events` default to
    /// `nil` (read live) — `observeCalendar`'s `calendar.$upcoming` sink and
    /// `observeMonitorGating`'s two sinks (the settings combineLatest and the
    /// `permissions.$statuses` one) pass their own emitted values explicitly
    /// instead, for the same stale-`willSet`-read reason documented on
    /// `applyMonitorState`.
    private func recomputeCalendarActivity(activityToggleOn: Bool? = nil,
                                            calendarPermissionGranted: Bool? = nil,
                                            events: [CalendarEvent]? = nil) {
        calendarThresholdTask.cancel()

        guard (activityToggleOn ?? settings.notchActivityCalendarEventEnabled),
              (calendarPermissionGranted ?? (permissions.statuses[.calendar] == .granted))
        else {
            activities.dismiss(kind: .calendarEvent)
            return
        }

        let now = Date()
        let upcoming = events ?? calendar.upcoming
        if let activity = Self.calendarEventSoonActivity(events: upcoming, now: now) {
            activities.post(activity)
        } else {
            activities.dismiss(kind: .calendarEvent)
        }
        scheduleNextCalendarBoundary(now: now, events: upcoming)
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
    private func scheduleNextCalendarBoundary(now: Date, events: [CalendarEvent]? = nil) {
        let next = Self.nextCalendarBoundary(events: events ?? calendar.upcoming, now: now)
        calendarThresholdTask.reschedule(to: next) { [weak self] in self?.recomputeCalendarActivity() }
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
                // change. Passes `calendarEnabled` straight through — not a
                // no-arg call re-reading `settings.notchActivityCalendarEventEnabled`
                // from inside this same combineLatest sink, which would see
                // the stale pre-change value (see `applyMonitorState`'s doc
                // comment).
                self?.recomputeCalendarActivity(activityToggleOn: calendarEnabled)
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
            .sink { [weak self] statuses in
                // Uses the emitted `statuses` dict directly rather than
                // re-reading `permissions.statuses` — the same `@Published`
                // stale-`willSet`-read hazard as everywhere else in this
                // file (see `applyMonitorState`'s doc comment): this sink IS
                // subscribed to `permissions.$statuses` itself.
                let calendarGranted = statuses[.calendar] == .granted
                self?.applyMonitorState(calendarPermissionGranted: calendarGranted)
                self?.recomputeCalendarActivity(calendarPermissionGranted: calendarGranted)
            }
            .store(in: &cancellables)
    }

    /// Re-applies `recomputeTimerActivity` whenever the notch master switch or
    /// the timer-activity toggle changes — mirrors `observeHUDGating`'s exact
    /// shape. `dropFirst` skips the redundant initial delivery; `init` already
    /// calls `recomputeTimerActivity()` once directly. Passes both emitted
    /// values straight through rather than letting `recomputeTimerActivity`
    /// re-read `settings.notchEnabled`/`settings.notchActivityTimerEnabled`
    /// itself, which — subscribed to those exact two publishers — would see
    /// the stale pre-change value (see `applyMonitorState`'s doc comment).
    private func observeTimerGating() {
        settings.$notchEnabled
            .combineLatest(settings.$notchActivityTimerEnabled)
            .dropFirst()
            .sink { [weak self] notchEnabled, timerEnabled in
                guard let self else { return }
                self.recomputeTimerActivity(toggleOn: timerEnabled, notchPresenting: notchEnabled && self.isPresenting)
            }
            .store(in: &cancellables)
    }

    /// Re-applies `applyMonitorState` whenever the notch's own state machine
    /// changes — specifically so the Calendar widget becoming (or stopping
    /// being) the currently-`.expanded` widget (and, M7, the Duo pane
    /// becoming/stopping being `.expanded(.nowPlaying)`) is re-evaluated the
    /// same tick, which `calendarServiceShouldRun` needs. The initial
    /// delivery every `@Published` makes at subscription time is harmless
    /// here (unlike the `dropFirst()` sinks above): `applyMonitorState` is
    /// idempotent, and this runs before `init`'s own explicit final call
    /// anyway. Passes the emitted `state` straight through — not a no-arg
    /// call re-reading `viewModel.state` from inside this exact sink, which
    /// would see the stale pre-transition value (see `applyMonitorState`'s
    /// doc comment) — which matters now more than ever: a transition INTO
    /// `.expanded(.nowPlaying)` while Duo is active must start
    /// `CalendarService` the same tick, not one state change late.
    private func observeNotchState() {
        viewModel.$state
            .sink { [weak self] state in self?.applyMonitorState(state: state) }
            .store(in: &cancellables)
    }

    /// M7: re-applies `applyMonitorState` whenever `duoActive` itself changes
    /// (the Duo setting toggled, Calendar's own enabled state or permission
    /// changing — see `AppDelegate.recomputeDuoActive`) — needed alongside
    /// `observeNotchState` above so `calendarServiceShouldRun`'s new
    /// `duoActive` input is re-evaluated the moment EITHER of its two
    /// dependencies (state, duoActive) changes, not just state. `dropFirst`
    /// skips the redundant initial delivery; `init`'s own final
    /// `applyMonitorState()` call already covers the starting value. Passes
    /// the emitted value through for the same stale-`willSet`-read reason as
    /// every other sink here.
    private func observeDuoActive() {
        viewModel.$duoActive
            .dropFirst()
            .sink { [weak self] duoActive in self?.applyMonitorState(duoActive: duoActive) }
            .store(in: &cancellables)
    }

    // MARK: - HUD (volume, M5; brightness/intercept mode removed M11)
    //
    // A single data source: `VolumeMonitor`'s CoreAudio listeners fire for
    // every volume/mute change regardless of who caused it (a hardware key,
    // a Control Center slider drag, another app) — see `handleVolumeEvent`.
    // This is permission-free and needs no dedupe: M11 removed the
    // Accessibility-gated intercept mode (`MediaKeyInterceptor`) and the
    // brightness HUD (`BrightnessMonitor` — brightness had no observe mode to
    // fall back to, so once intercept went, brightness had nothing left to
    // show) entirely, so observe mode is now the only producer of
    // `.hudVolume` and there's no second write path to double-post against.

    private func observeVolume() {
        volume.events
            .sink { [weak self] event in self?.handleVolumeEvent(event) }
            .store(in: &cancellables)
    }

    private func handleVolumeEvent(_ event: VolumeEvent) {
        guard settings.notchHudEnabled else { return }
        switch event {
        case .volumeChanged(let level, let muted):
            activities.post(Self.volumeActivity(level: level, muted: muted))
        }
    }

    static func volumeActivity(level: Float, muted: Bool) -> LiveActivity {
        let symbol = volumeSymbol(level: level, muted: muted)
        return LiveActivity(kind: .hudVolume,
                             leading: .icon(systemName: symbol),
                             trailing: .gauge(Double(level), systemName: symbol),
                             duration: 1.5,
                             priority: 300)
    }

    /// SF Symbol for the wing icon — muted (or a literal 0 level) always
    /// reads as the slashed glyph regardless of the last non-zero level.
    static func volumeSymbol(level: Float, muted: Bool) -> String {
        guard !muted, level > 0 else { return "speaker.slash.fill" }
        switch level {
        case ..<(1.0 / 3.0): return "speaker.wave.1.fill"
        case ..<(2.0 / 3.0): return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// Whether the volume HUD should be observing right now — a pure
    /// function of exactly the causes that decide it (the HUD master toggle,
    /// whether there's anywhere to present), so `--selftest` can drive both
    /// combinations directly. M11 collapsed this from a three-way
    /// off/observe/intercept mode (gated on an Accessibility grant) down to
    /// a plain on/off now that intercept mode is gone.
    enum HUDMode: Equatable { case off, observe }

    static func intendedHUDMode(hudEnabled: Bool, notchPresenting: Bool) -> HUDMode {
        notchPresenting && hudEnabled ? .observe : .off
    }

    /// Starts/stops `volume` to match the current settings — called from
    /// every trigger that could change the answer: `init`'s final call,
    /// `observeHUDGating`'s settings sink, and the presentation/notch-state
    /// sinks above (mirroring exactly which sinks call `applyMonitorState`,
    /// for the same reasons). Also gated on `startsMonitors`, like
    /// `applyMonitorState`.
    private func applyHUDState(notchEnabled: Bool? = nil, hudEnabled: Bool? = nil) {
        guard startsMonitors else { return }
        let notchOn = (notchEnabled ?? settings.notchEnabled) && isPresenting
        let mode = Self.intendedHUDMode(hudEnabled: hudEnabled ?? settings.notchHudEnabled, notchPresenting: notchOn)

        switch mode {
        case .off:
            volume.stop()
            activities.dismiss(kind: .hudVolume)
        case .observe:
            volume.start()
        }
    }

    /// Re-applies `applyHUDState` whenever the notch master switch or the
    /// HUD toggle changes. `dropFirst` skips the redundant initial delivery,
    /// same as `observeMonitorGating` — `init` already calls `applyHUDState()`
    /// once directly.
    private func observeHUDGating() {
        settings.$notchEnabled
            .combineLatest(settings.$notchHudEnabled)
            .dropFirst()
            .sink { [weak self] notchEnabled, hudEnabled in
                self?.applyHUDState(notchEnabled: notchEnabled, hudEnabled: hudEnabled)
            }
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
                self.applyHUDState()
                self.recomputeTimerActivity()
            }
            .store(in: &cancellables)
    }

    /// The battery/Bluetooth monitors only run when their own settings
    /// toggle is on *and* the notch panel itself is enabled *and* there's
    /// somewhere to actually show a wing (`isPresenting`) — an external-only
    /// clamshell setup, or a moment where the notch's screen has been lost,
    /// leaves nowhere for either activity to render, so idling the monitors
    /// there saves the IOKit run-loop source / CoreAudio listener for
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
    /// IOKit/CoreAudio/EventKit state no matter how many settings toggles
    /// it flips.
    ///
    /// Calendar's `start()`/`stop()` here is now this router's ONLY vote —
    /// see `calendarServiceShouldRun` and `CalendarService`'s own doc comment
    /// on the ownership fix this replaced (the old
    /// `isCalendarWidgetPresented()` closure this router used to defer to).
    /// `calendarPermissionGranted`/`state`/`duoActive` are optionals, defaulting
    /// to `nil` (read live) — the same "explicit value from a sink observing
    /// THAT exact publisher, live read everywhere else" split every other
    /// parameter here already follows. `observeNotchState`'s `viewModel.$state`
    /// sink and the new `observeDuoActive`'s `viewModel.$duoActive` sink pass
    /// their emitted values explicitly for the same reason
    /// `observeMonitorGating`'s combineLatest sink already passes
    /// `notchEnabled`/`batteryEnabled`/`bluetoothEnabled`/`calendarEnabled`:
    /// `@Published` delivers from `willSet`, before backing storage updates,
    /// so re-reading `viewModel.state`/`viewModel.duoActive`/
    /// `permissions.statuses` from inside a sink subscribed to that exact
    /// publisher would otherwise see the STALE pre-change value.
    private func applyMonitorState(notchEnabled: Bool? = nil, batteryEnabled: Bool? = nil,
                                    bluetoothEnabled: Bool? = nil, calendarEnabled: Bool? = nil,
                                    calendarPermissionGranted: Bool? = nil,
                                    state: NotchState? = nil, duoActive: Bool? = nil) {
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
            permissionGranted: calendarPermissionGranted ?? (permissions.statuses[.calendar] == .granted),
            notchPresenting: isPresenting,
            widgetEnabled: settings.notchCalendarEnabled,
            state: state ?? viewModel.state,
            activityToggleOn: calendarEnabled ?? settings.notchActivityCalendarEventEnabled,
            duoActive: duoActive ?? viewModel.duoActive)
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
    /// M7: extended with `duoActive` — Duo (Now Playing + Calendar side by
    /// side, see `NotchViewModel.duoActive`) shows the Calendar pane's own
    /// agenda even when the event-soon toggle is off and the Calendar widget
    /// itself isn't the one `.expanded`, so `CalendarService` must be running
    /// in that state too, or the Duo pane renders an empty agenda. `duoActive`
    /// alone isn't sufficient on its own (it stays true even while some OTHER
    /// widget, or nothing, is expanded) — it only matters here alongside the
    /// Duo pane actually being the thing on screen, i.e. `state ==
    /// .expanded(.nowPlaying)` (Duo always renders as the Now Playing widget
    /// slot widened to include Calendar — see `NotchRootView.duoContent`).
    static func calendarServiceShouldRun(permissionGranted: Bool, notchPresenting: Bool,
                                          widgetEnabled: Bool, state: NotchState,
                                          activityToggleOn: Bool, duoActive: Bool) -> Bool {
        guard permissionGranted, notchPresenting else { return false }
        let widgetOpen = widgetEnabled && state == .expanded(.calendar)
        let duoShowing = duoActive && state == .expanded(.nowPlaying)
        return widgetOpen || activityToggleOn || duoShowing
    }

    // MARK: - Timers (M6)
    //
    // Two producers share the single `.timer` `LiveActivity.Kind`:
    //   - `handleTimerCompletion`: a transient (10s), higher-priority (250)
    //     "<label> done" notice the instant `TimerService.completions` fires,
    //     plus a system sound — gated only on the settings toggle, not on
    //     presentation, since a finished timer is worth a sound even if
    //     there's nowhere to show a wing right now (posting to `activities`
    //     with nowhere to render it is harmless; matches how
    //     `handlePowerEvent`/`handleBluetoothEvent` above gate purely on their
    //     own toggle too, leaning on their monitors only running while
    //     presenting instead of re-checking it per event — this event source
    //     has no such lifecycle to lean on, see `timers`'s own doc comment,
    //     so the sound plays regardless).
    //   - `recomputeTimerActivity`: a sticky (lower-priority, 110) ambient
    //     countdown wing shown for as long as some timer is actually counting
    //     down, refreshed on a boundary `Task` (never a repeating `Timer`)
    //     rather than a live per-second tick — that per-second cadence is
    //     `TimersExpandedView`'s own concern, gated on the widget actually
    //     being presented.
    //
    // `LiveActivityCenter.post`'s own same-kind supersession means posting the
    // completion notice while the ambient wing is showing simply replaces it
    // (the completion's higher priority would win regardless); once the
    // completion's own expiry dismisses it, `armTimerRefresh` — scheduled
    // right alongside the completion post — re-evaluates so a still-running
    // OTHER timer's ambient wing reappears instead of staying dismissed with
    // nothing left to notice `$timers` didn't change during that window.

    private func observeTimers() {
        timers.completions
            .sink { [weak self] timer in self?.handleTimerCompletion(timer) }
            .store(in: &cancellables)
        // Takes the emitted array directly (`liveTimers`) rather than
        // re-reading `timers.timers` from inside the sink — `@Published`
        // delivers to subscribers from `willSet`, BEFORE its own backing
        // storage is actually updated, so a synchronous read of
        // `timers.timers` here would see the value from BEFORE this exact
        // mutation (e.g., still empty the instant a first timer is
        // `start()`-ed). The emitted parameter itself carries the real,
        // up-to-date array, so `recomputeTimerActivity` is written to accept
        // it explicitly for this one call site.
        timers.$timers
            .sink { [weak self] liveTimers in self?.recomputeTimerActivity(timers: liveTimers) }
            .store(in: &cancellables)
    }

    private func handleTimerCompletion(_ timer: NotchTimer) {
        guard settings.notchActivityTimerEnabled else { return }
        let expiresAt = Date().addingTimeInterval(Self.timerCompletionDuration)
        // Recorded BEFORE posting — see `completionAlertUntil`'s own doc
        // comment: `recomputeTimerActivity` checks this on every call, so it
        // must already be set by the time anything downstream of `post`
        // (there's nothing synchronous here, but the ordering is the
        // deliberate part) could possibly race a recompute.
        completionAlertUntil = expiresAt
        activities.post(Self.timerCompletionActivity(label: timer.label))
        NSSound(named: "Glass")?.play()
        armTimerRefresh(at: expiresAt.addingTimeInterval(0.1))
    }

    static let timerCompletionDuration: TimeInterval = 10
    static let timerCompletionPriority = 250
    static let timerAmbientPriority = 110

    static func timerCompletionActivity(label: String) -> LiveActivity {
        LiveActivity(kind: .timer,
                     leading: .icon(systemName: "timer"),
                     trailing: .text("\(label) done"),
                     duration: timerCompletionDuration,
                     priority: timerCompletionPriority)
    }

    /// Non-`nil` for exactly `timerCompletionDuration` seconds after
    /// `handleTimerCompletion` posts a "<label> done" notice — the code-review
    /// fix for a real bug: without this, ANY mutation during that 10s window
    /// (pausing, resuming, cancelling, or starting a DIFFERENT timer — every
    /// one of which republishes `timers.$timers`) fed straight into
    /// `recomputeTimerActivity`, which would immediately post the ambient
    /// wing over top of the still-showing completion notice, dismissing it
    /// early. `recomputeTimerActivity` checks this first and, while it's in
    /// the future, does nothing at all — not even cancels the already-armed
    /// `timerRefreshTask` (see `handleTimerCompletion`'s own `armTimerRefresh`
    /// call, scheduled for just past this exact expiry) — so the completion
    /// notice is always left to run its full course and expire naturally,
    /// then that same already-scheduled refresh re-evaluates once it does.
    private var completionAlertUntil: Date?

    /// Re-evaluates the ambient countdown wing and re-arms the next refresh —
    /// called from every trigger that could change the answer: `timers.$timers`
    /// (a start/pause/resume/cancel/completion-reap — passing its OWN emitted
    /// array explicitly, see `observeTimers`'s doc comment on why), the
    /// settings/presentation gating sinks below, `init`'s final call, and its
    /// own scheduled refresh task (these last few pass `nil`, since none of
    /// them run from inside a `$timers` willSet callback — reading
    /// `timers.timers` directly at those call sites is safe and current).
    private func recomputeTimerActivity(timers liveTimers: [NotchTimer]? = nil,
                                         toggleOn: Bool? = nil, notchPresenting: Bool? = nil) {
        let now = Date()
        // While a completion notice is still showing, this must not touch
        // the `.timer` activity at all — see `completionAlertUntil`'s doc
        // comment. Deliberately returns before even cancelling
        // `timerRefreshTask`: the refresh already armed by
        // `handleTimerCompletion` (for just past this exact expiry) is
        // exactly what should run next, not whatever triggered this call.
        if let completionAlertUntil, now < completionAlertUntil { return }
        completionAlertUntil = nil

        timerRefreshTask.cancel()
        let currentTimers = liveTimers ?? timers.timers
        switch Self.timerWingState(timers: currentTimers,
                                    toggleOn: toggleOn ?? settings.notchActivityTimerEnabled,
                                    notchPresenting: notchPresenting ?? (settings.notchEnabled && isPresenting),
                                    at: now) {
        case .hidden:
            activities.dismiss(kind: .timer)
        case .running(let deadline, let line):
            activities.post(LiveActivity(kind: .timer,
                                          leading: .icon(systemName: "timer"),
                                          trailing: .text(line),
                                          duration: nil,
                                          priority: Self.timerAmbientPriority))
            armTimerRefresh(at: Self.nextTimerRefreshBoundary(deadline: deadline, now: now))
        case .paused(let line):
            // No refresh armed here: a paused timer's remaining is frozen
            // (see `NotchTimer.remaining(at:)`) — nothing about this text
            // will change on its own, unlike a running countdown. The next
            // recompute comes from whatever mutation changes the picture
            // (a resume, a new timer starting, cancelling the last paused
            // one, ...), same as every other `$timers`-driven call site.
            activities.post(LiveActivity(kind: .timer,
                                          leading: .icon(systemName: "pause.circle"),
                                          trailing: .text(line),
                                          duration: nil,
                                          priority: Self.timerAmbientPriority))
        }
    }

    /// The single cancellable refresh task backing the ambient wing's text —
    /// backed by the shared `DeadlineTask` helper, matching
    /// `calendarThresholdTask`'s "exactly one deadline in flight" shape. Also
    /// reused by `handleTimerCompletion` to re-check once the transient
    /// completion notice's own expiry passes (see this section's doc
    /// comment).
    private let timerRefreshTask = DeadlineTask()

    private func armTimerRefresh(at date: Date) {
        timerRefreshTask.reschedule(to: date) { [weak self] in self?.recomputeTimerActivity() }
    }

    /// What the ambient `.timer` wing should show right now — a pure function
    /// of exactly the causes that decide it, matching `intendedHUDMode`'s/
    /// `calendarServiceShouldRun`'s shape so `--selftest` can drive every
    /// combination directly (including the code-review fix this adds: a
    /// paused-but-not-empty timer list).
    enum TimerWingState: Equatable {
        /// Toggle off, notch not presenting, or no timers at all.
        case hidden
        /// At least one timer is counting down — `deadline` is the earliest
        /// unpaused one's `endDate` (what the next refresh should arm
        /// against), `line` its formatted remaining time.
        case running(deadline: Date, line: String)
        /// Timers exist, but every one of them is paused — the code-review
        /// fix: previously this fell through to `.hidden` (`hasRunningTimer`
        /// was `false`), dismissing the wing entirely the instant the ONLY
        /// running timer was paused, even though there was still a paused
        /// timer whose state was worth showing. `line` is the nearest paused
        /// timer's frozen remaining time.
        case paused(line: String)
    }

    static func timerWingState(timers: [NotchTimer], toggleOn: Bool, notchPresenting: Bool, at now: Date) -> TimerWingState {
        guard toggleOn, notchPresenting, !timers.isEmpty else { return .hidden }
        if let deadline = TimerService.nextDeadline(in: timers, after: now),
           let line = TimersWidget.nearestRemainingLine(timers: timers, at: now) {
            return .running(deadline: deadline, line: line)
        }
        if let line = TimersWidget.nearestPausedRemainingLine(timers: timers, at: now) {
            return .paused(line: line)
        }
        return .hidden
    }

    /// The next instant the ambient wing's displayed countdown text should
    /// refresh: once a minute while more than a minute remains (matching
    /// `nextMinuteBoundary`'s cadence for the calendar wing, and
    /// `TimersWidget.formatAmbientRemaining`'s whole-minutes text over that
    /// same window), or once a SECOND once under a minute remains, matching
    /// `formatAmbientRemaining`'s switch to `m:ss` text there — anything
    /// coarser would show a seconds digit that visibly doesn't move between
    /// refreshes. This is a deliberate, narrow exception to the notch suite's
    /// no-frequent-timers perf contract: it's bounded to at most 60 wakes
    /// (once the countdown is already inside its final minute) rather than
    /// an open-ended per-second timer, and it only exists at all because a
    /// countdown wing that's about to finish reads as broken if its last
    /// minute visibly freezes. Also wakes at the exact instant the countdown
    /// crosses under a minute, so the cadence switch itself doesn't wait up
    /// to a full minute late.
    static func nextTimerRefreshBoundary(deadline: Date, now: Date) -> Date {
        let remaining = deadline.timeIntervalSince(now)
        let tick = remaining > 60 ? nextMinuteBoundary(after: now) : nextTickBoundary(after: now, every: 1)
        let crossover = deadline.addingTimeInterval(-60)
        return crossover > now ? min(tick, crossover) : tick
    }

    /// The next wall-clock instant strictly after `now` that's an even
    /// multiple of `interval` seconds since the reference date — the general
    /// form of `nextMinuteBoundary`'s `interval == 60` case, used here for
    /// the under-a-minute 10s refresh cadence.
    static func nextTickBoundary(after now: Date, every interval: TimeInterval) -> Date {
        let epoch = now.timeIntervalSinceReferenceDate
        let nextEpoch = (epoch / interval).rounded(.down) * interval + interval
        return Date(timeIntervalSinceReferenceDate: nextEpoch)
    }
}
