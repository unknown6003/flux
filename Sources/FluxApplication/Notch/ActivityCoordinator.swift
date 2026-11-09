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
    private var mediaKey: String?
    private var media: MediaSnapshot?
    private var artworkID: UUID?
    private var artwork: NSImage?
    private var calendarTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private lazy var images = ArtworkPipeline { [weak self] id, image in
        guard let self, self.active, self.presenting, self.queue.current?.kind == .nowPlaying,
              self.artworkID == id else { return }
        self.artwork = image.map { NSImage(cgImage: $0.image, size: .zero) }
        self.publishCurrent()
    }

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
        images.clear(); artworkID = nil; artwork = nil; media = nil; mediaKey = nil
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
        if !presenting { images.clear(); artworkID = nil; artwork = nil }
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
        if !enabled(.nowPlaying) { media = nil; mediaKey = nil; images.clear(); artworkID = nil; artwork = nil }
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
        case .media(let state):
            guard enabled(.nowPlaying), case .ready(let snapshot) = state,
                  let snapshot, snapshot.playing else {
                media = nil; mediaKey = nil; queue.remove(.nowPlaying); return
            }
            media = snapshot
            let key = "\(snapshot.source?.rawValue ?? "")\u{0}\(snapshot.title)\u{0}\(snapshot.artist)"
            let newTrack = mediaKey != key
            mediaKey = key
            post(.nowPlaying, .artwork, .symbol("waveform"), priority: 50, duration: nil, updateOnly: !newTrack)
            queueChanged()
        case .calendar(let result):
            if enabled(.calendarEvent), case .ready(let snapshot) = result { agenda = snapshot.entries }
            else { agenda = [] }
            refreshCalendar()
        case .shelfCopyFinished(let added, _):
            guard added > 0, enabled(.shelfDrop) else { return }
            post(.shelfDrop, .symbol("tray.and.arrow.down.fill"), .text(String(min(added, 20))), priority: 100, duration: 4)
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
        let symbol = snapshot.muted ? "speaker.slash.fill" : (snapshot.level > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill")
        post(.soundHUD, .none, .soundGauge(value: Double(snapshot.level), symbol: symbol), priority: 300, duration: 1.5)
    }

    /// Device identity stays with the device owner. Only a local label and
    /// category symbol cross into the compact view.
    public func receiveDevice(name: String, symbol: String, connected: Bool, percent: Int?) {
        guard active, enabled(.bluetoothDevice) else { return }
        let text = connected ? percent.map { "\(min(max($0, 0), 100))%" } ?? String(name.prefix(120)) : "Disconnected"
        post(.bluetoothDevice, .symbol(symbol), .text(text), priority: 100, duration: 4)
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
        let symbol = charging ? "battery.100.bolt" : "battery.\((percent / 25) * 25)"
        post(.battery, .symbol(symbol), .text("\(percent)%"), priority: 200,
             duration: warning ? nil : 4, tint: warning ? .warning : .normal, updateOnly: updateOnly)
    }

    private func completed(_ timer: Countdown) {
        guard active, enabled(.timer) else { return }
        completionUntil = now().addingTimeInterval(10)
        timerID = nil
        post(.timer, .symbol("timer"), .text("\(String(timer.label.prefix(100))) done"), priority: 250, duration: 10)
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
            ?? timers.timers.first
        guard let timer else { timerID = nil; queue.remove(.timer); return }
        let seconds = Int(ceil(timer.remaining(at: date)))
        let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
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
        let events = agenda.filter { !$0.allDay && $0.start > date }
        let next = events.min { $0.start < $1.start }
        if let next, next.start.timeIntervalSince(date) <= 600 {
            let minutes = Int(ceil(next.start.timeIntervalSince(date) / 60))
            let changed = calendarID != next.id
            calendarID = next.id
            post(.calendarEvent, .symbol("calendar"), .text("\(String(next.title.prefix(90))) · in \(minutes)m"),
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
        if presenting, queue.current?.kind == .nowPlaying, let id = media?.artworkID,
           let bytes = media?.artwork {
            if artworkID != id { artworkID = id; artwork = nil; images.submit(id: id, bytes: bytes) }
        } else { images.clear(); artworkID = nil; artwork = nil }
        publishCurrent()
        publishing = false
    }

    private func publishCurrent() {
        publish(queue.current, queue.current?.kind == .nowPlaying ? artwork : nil, queue.count, queue.restorableCount)
    }

    private func post(_ kind: ActivityKind, _ leading: ActivityWing, _ trailing: ActivityWing,
                      priority: Int, duration: TimeInterval?, tint: ActivityTint = .normal,
                      updateOnly: Bool = false) {
        guard let item = try? ActivityItem(kind: kind, leading: leading, trailing: trailing,
                                          priority: priority, tint: tint, duration: duration) else { return }
        if updateOnly { queue.updateIfPresent(item) } else { queue.post(item) }
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
