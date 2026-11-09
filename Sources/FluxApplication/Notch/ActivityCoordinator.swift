import AppKit
import FluxCore
import FluxPlatform
import FluxUI

/// Local feed values become compact activities here, never telemetry. There
/// is no idle tick: countdown text refreshes only while that activity is on
/// screen; calendar work sleeps until a threshold, start, or visible minute.
@MainActor
public final class ActivityCoordinator {
    public let queue: ActivityQueue
    public let timers: Countdowns
    private let preferences: PreferenceStore
    private let now: @MainActor () -> Date
    private let publish: @MainActor (ActivityItem?, NSImage?, Int, Int) -> Void
    private let timerCompleted: @MainActor (Countdown) -> Void
    private var active = false
    private var presenting = false
    private var publishing = false
    private var refreshingTimer = false
    private var refreshingCalendar = false
    private var power = PowerTransitions()
    private var lowWarning = false
    private var overflowCount = 0
    private var lastVolume: VolumeSnapshot?
    private var agenda: [AgendaEntry] = []
    private var calendarID: String?
    private var timerID: UUID?
    private var completionUntil: Date?
    private var calendarTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    public init(preferences: PreferenceStore, now: @escaping @MainActor () -> Date = { .now },
                publish: @escaping @MainActor (ActivityItem?, NSImage?, Int, Int) -> Void,
                timerCompleted: @escaping @MainActor (Countdown) -> Void) {
        self.preferences = preferences; self.now = now
        self.publish = publish; self.timerCompleted = timerCompleted
        queue = ActivityQueue(now: now)
        timers = Countdowns(now: now)
        queue.onChange = { [weak self] in self?.queueChanged() }
        timers.onChange = { [weak self] in self?.refreshTimer() }
        timers.onCompletion = { [weak self] in self?.completed($0) }
    }

    deinit { calendarTask?.cancel(); timerTask?.cancel() }

    public func start() { guard !active else { return }; active = true; refreshPreferences() }
    public func stop() {
        guard active else { return }
        active = false
        presenting = false
        calendarTask?.cancel(); calendarTask = nil
        timerTask?.cancel(); timerTask = nil
        agenda = []; calendarID = nil; timerID = nil; completionUntil = nil
        power = PowerTransitions(); lowWarning = false; lastVolume = nil; overflowCount = 0
        timers.cancelAll()
        queue.clear()
        publish(nil, nil, 0, 0)
    }

    public func setPresenting(_ presenting: Bool) {
        guard self.presenting != presenting else { return }
        self.presenting = presenting
        guard active else { return }
        refreshTimer()
        refreshCalendar()
        queueChanged()
    }

    public func refreshPreferences() {
#if FLUX_PERFORMANCE_TRACE
        PerformanceTrace.record(.activitiesReconcile)
#endif
        guard active else { return }
        for kind in ActivityKind.allCases where !enabled(kind) { queue.remove(kind) }
        if !enabled(.menuBarOverflow) { overflowCount = 0 }
        if !enabled(.battery) { power = PowerTransitions(); lowWarning = false }
        if !enabled(.calendarEvent) { agenda = []; calendarID = nil }
        if !enabled(.soundHUD) { lastVolume = nil }
        refreshTimer()
        refreshCalendar()
    }

    /// Wake and time-zone/clock changes reconcile finite deadlines once.
    public func reconcile() {
        guard active else { return }
        timers.reconcile(); queue.reconcile()
        refreshTimer(); refreshCalendar()
    }

    public func perform(_ action: CompactNotchAction) {
        guard active else { return }
        switch action {
        case .cycle: queue.cycle()
        case .dismissActivity: queue.dismissCurrent()
        case .restoreActivity: queue.restoreLastDismissed()
        case .expand: break // The window owns expansion.
        }
    }

    public func receive(_ event: WidgetEvent) {
        guard active else { return }
        switch event {
        case .media:
            // 0.21.35 never showed a Now Playing wing. Media stays in the widget.
            break
        case .calendar(let result):
            if enabled(.calendarEvent), case .ready(let snapshot) = result { agenda = snapshot.entries }
            else { agenda = [] }
            refreshCalendar()
        case .shelfDropAccepted(let count):
            guard count > 0, enabled(.shelfDrop) else { return }
            post(.shelfDrop, .symbol("tray.and.arrow.down.fill"), .text("Adding \(count)\u{2026}"),
                 priority: 120, duration: 2.5)
        case .shelfCopyFinished(let added, _):
            guard added > 0, enabled(.shelfDrop) else { return }
            post(.shelfDrop, .symbol("tray.and.arrow.down.fill"), .text("Added \(added)"),
                 priority: 120, duration: 2.5, updateOnly: true)
        case .camera: break
        }
    }

    public func receiveBattery(_ snapshot: PowerSnapshot?) {
        guard active, enabled(.battery) else { return }
        guard let snapshot else { power = PowerTransitions(); lowWarning = false; queue.remove(.battery); return }
        let transitions = power.accept(snapshot)
        let pluggedIn = transitions.contains { if case .connected = $0 { true } else { false } }
        for transition in transitions {
            switch transition {
            case .connected(let percent):
                lowWarning = false
                postBattery(percent, charging: true, warning: false)
            case .disconnected(let percent):
                postBattery(percent, charging: false, warning: false)
            case .low(let percent):
                postBattery(percent, charging: false, warning: true, updateOnly: lowWarning)
                lowWarning = true
            case .recovered:
                lowWarning = false
                if !pluggedIn { queue.remove(.battery) }
            }
        }
    }

    public func receiveVolume(_ snapshot: VolumeSnapshot?, force: Bool = false) {
        guard active, enabled(.soundHUD) else { return }
        defer { lastVolume = snapshot }
        guard let snapshot, force || lastVolume.map({ snapshot != $0 }) == true else { return }
        let symbol = Self.soundSymbol(level: snapshot.level, muted: snapshot.muted)
        post(.soundHUD, .none, .soundGauge(value: Double(snapshot.level), symbol: symbol), priority: 300, duration: 1.5)
    }

    /// Device identity stays with the device owner. Only a local label and
    /// category symbol cross into the compact view.
    public func receiveDevice(name: String, symbol: String, connected: Bool, percent: Int?) {
        guard active, enabled(.bluetoothDevice) else { return }
        let trailing: ActivityWing
        if !connected { trailing = .text("Disconnected") }
        else if let percent {
            let value = min(max(percent, 0), 100)
            trailing = .symbolText(symbol: Self.batterySymbol(percent: value, charging: false), text: "\(value)%")
        } else { trailing = .text(String(name.prefix(120))) }
        post(.bluetoothDevice, .symbol(symbol), trailing, priority: 100, duration: 4)
    }

    public func receiveDevice(_ event: AccessoryConnection) {
        switch event {
        case .connected(let accessory):
            receiveDevice(name: accessory.name, symbol: accessory.symbol, connected: true, percent: accessory.percent)
        case .disconnected(let accessory):
            receiveDevice(name: accessory.name, symbol: accessory.symbol, connected: false, percent: nil)
        }
    }

    public func setOverflowCount(_ count: Int) {
        guard active else { return }
        guard count > 0, enabled(.menuBarOverflow) else {
            overflowCount = 0
            queue.remove(.menuBarOverflow)
            return
        }
        // One overflow episode lasts until the bar fits again. Repeated
        // scans and count changes do not undo dismissal during that episode.
        let newEpisode = overflowCount == 0
        overflowCount = min(count, 512)
        post(.menuBarOverflow, .symbol("exclamationmark.triangle.fill"), .text(String(overflowCount)),
             priority: 150, duration: nil, updateOnly: !newEpisode)
    }

    private func postBattery(_ percent: Int, charging: Bool, warning: Bool, updateOnly: Bool = false) {
        post(.battery, .symbol(Self.batterySymbol(percent: percent, charging: charging)), .text("\(percent)%"), priority: 200,
             duration: warning ? nil : 4, tint: warning ? .warning : .normal, updateOnly: updateOnly)
    }

    private func completed(_ timer: Countdown) {
        guard active, enabled(.timer) else { return }
        completionUntil = now().addingTimeInterval(10)
        timerID = nil
        post(.timer, .symbol("timer"), .text("\(String(timer.label.prefix(100))) done"), priority: 250, duration: 10)
        NSSound(named: "Glass")?.play()
        timerCompleted(timer)
    }

    private func refreshTimer() {
        guard !refreshingTimer else { return }
        refreshingTimer = true
        defer { refreshingTimer = false }
        timerTask?.cancel(); timerTask = nil
        guard active, enabled(.timer) else { completionUntil = nil; timerID = nil; queue.remove(.timer); return }
        let date = now()
        if let completionUntil, date < completionUntil {
            // Dismissing the completion removes the queue's expiry deadline.
            // Keep our own one-shot boundary so another timer returns on time.
            if presenting {
                let wake = ContinuousClock.now.advanced(by: .seconds(completionUntil.timeIntervalSince(date)))
                timerTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: wake, clock: .continuous) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.refreshTimer()
                }
            }
            return
        }
        completionUntil = nil
        let timer = timers.timers.filter { !$0.isPaused }.min { $0.remaining(at: date) < $1.remaining(at: date) }
            ?? timers.timers.filter(\.isPaused).min { $0.remaining(at: date) < $1.remaining(at: date) }
        guard let timer else { timerID = nil; queue.remove(.timer); return }
        let text = Self.countdown(timer.remaining(at: date))
        let newTimer = timerID != timer.id
        timerID = timer.id
        post(.timer, .symbol(timer.isPaused ? "pause.circle" : "timer"), .text(text), priority: 110, duration: nil, updateOnly: !newTimer)
        guard presenting, queue.current?.kind == .timer, !timer.isPaused else { return }
        timerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshTimer()
        }
    }

    private func refreshCalendar() {
        guard !refreshingCalendar else { return }
        refreshingCalendar = true
        defer { refreshingCalendar = false }
        calendarTask?.cancel(); calendarTask = nil
        guard active, enabled(.calendarEvent) else { calendarID = nil; queue.remove(.calendarEvent); return }
        let date = now()
        let events = agenda.filter { !$0.allDay && $0.start >= date }
        let next = events.min { $0.start < $1.start }
        if let next, next.start.timeIntervalSince(date) <= 600 {
            let changed = calendarID != next.id
            calendarID = next.id
            post(.calendarEvent, .symbol("calendar"),
                 .text(Self.relativeStartPhrase(title: String(next.title.prefix(90)), start: next.start, now: date)),
                 priority: 120, duration: nil, updateOnly: !changed)
        } else { calendarID = nil; queue.remove(.calendarEvent) }
        var boundaries = events.flatMap { [$0.start.addingTimeInterval(-600), $0.start] }.filter { $0 > date }
        if presenting, queue.current?.kind == .calendarEvent {
            boundaries.append(Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60))
        }
        guard let deadline = boundaries.min() else { return }
        calendarTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(date)))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshCalendar()
        }
    }

    private func queueChanged() {
        guard active, !publishing else { return }
        publishing = true
        if queue.current?.kind == .timer || completionUntil.map({ now() >= $0 }) == true { refreshTimer() }
        if queue.current?.kind == .calendarEvent { refreshCalendar() }
        publishCurrent()
        publishing = false
    }

    private func publishCurrent() {
        publish(queue.current, nil, queue.count, queue.restorableCount)
    }

    private func post(_ kind: ActivityKind, _ leading: ActivityWing, _ trailing: ActivityWing,
                      priority: Int, duration: TimeInterval?, tint: ActivityTint = .normal,
                      updateOnly: Bool = false) {
        guard let item = try? ActivityItem(kind: kind, leading: leading, trailing: trailing,
                                          priority: priority, tint: tint, duration: duration) else { return }
        if updateOnly { queue.updateIfPresent(item) } else { queue.post(item) }
    }

    // MARK: 0.21.35 wing text and symbols

    static func batterySymbol(percent: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100.bolt" }
        let clamped = max(0, min(100, percent))
        return "battery.\((clamped / 25) * 25)"
    }

    static func soundSymbol(level: Float, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        switch level {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(min(seconds, Double(Int32.max)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func relativeStartPhrase(title: String, start: Date, now: Date) -> String {
        guard start > now else { return "\(title) now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { return "\(title) now" }
        if minutes < 60 { return "\(title) in \(minutes)m" }
        let hours = Int((start.timeIntervalSince(now) / 3600).rounded())
        return "\(title) in \(hours)h"
    }

    private func enabled(_ kind: ActivityKind) -> Bool {
        guard preferences.value(for: Preferences.notchEnabled) else { return false }
        switch kind {
        case .battery: return preferences.value(for: Preferences.batteryEnabled)
        case .bluetoothDevice: return preferences.value(for: Preferences.bluetoothEnabled)
        case .timer: return preferences.value(for: Preferences.timerEnabled)
        case .shelfDrop: return preferences.value(for: Preferences.shelfEnabled)
        case .menuBarOverflow: return true
        case .nowPlaying: return preferences.value(for: Preferences.nowPlayingEnabled)
        case .calendarEvent: return preferences.value(for: Preferences.calendarEventEnabled)
        case .soundHUD: return preferences.value(for: Preferences.soundHUDEnabled)
        }
    }
}
