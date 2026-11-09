import AppKit
import FluxCore
import FluxPlatform

/// The application's single owner for notch features. Feed changes, queue
/// input, deadlines and the visible window meet here. The executable supplies
/// the remaining lock-screen bridge and the fixed error/report UI.
@MainActor public final class NotchSubsystem {
    public struct Callbacks {
        public var report: @MainActor (NotchRuntimeFailure) -> Void
        public var contentChanged: @MainActor (WidgetEvent) -> Void
        public var phaseChanged: @MainActor (SessionPhase) -> Void
        public var cameraRunning: @MainActor (Bool) -> Void
        public var accessChanged: @MainActor () -> Void
        public var timerCompleted: @MainActor (Countdown) -> Void
        public var makeLockScreenService: @MainActor () throws -> any FeatureServiceHandle

        public init(report: @escaping @MainActor (NotchRuntimeFailure) -> Void,
                    contentChanged: @escaping @MainActor (WidgetEvent) -> Void,
                    phaseChanged: @escaping @MainActor (SessionPhase) -> Void,
                    cameraRunning: @escaping @MainActor (Bool) -> Void,
                    accessChanged: @escaping @MainActor () -> Void,
                    timerCompleted: @escaping @MainActor (Countdown) -> Void,
                    makeLockScreenService: @escaping @MainActor () throws -> any FeatureServiceHandle) {
            self.report = report; self.contentChanged = contentChanged
            self.phaseChanged = phaseChanged; self.cameraRunning = cameraRunning
            self.accessChanged = accessChanged; self.timerCompleted = timerCompleted
            self.makeLockScreenService = makeLockScreenService
        }
    }

    private let preferences: PreferenceStore
    private let files: ApplicationFiles
    private let mediaScript: URL
    private let mediaFramework: URL
    private let callbacks: Callbacks
    private var active = false
    private lazy var activities: ActivityCoordinator = ActivityCoordinator(preferences: preferences,
        publish: { [weak self] item, image, count, restorable in
            self?.runtime.updateActivity(item, artwork: image, count: count, restorableCount: restorable)
        }, timerCompleted: { [weak self] in self?.callbacks.timerCompleted($0) })
    private lazy var runtime: NotchRuntime = NotchRuntime(preferences: preferences, files: files,
        mediaScript: mediaScript, mediaFramework: mediaFramework, callbacks: .init(
            report: { [weak self] in self?.callbacks.report($0) },
            event: { [weak self] event in
                self?.activities.receive(event)
                self?.callbacks.contentChanged(event)
            }, battery: { [weak self] in self?.activities.receiveBattery($0) },
            volume: { [weak self] state, force in self?.activities.receiveVolume(state, force: force) },
            device: { [weak self] in self?.activities.receiveDevice($0) },
            compactAction: { [weak self] in self?.activities.perform($0) },
            cameraRunning: { [weak self] in self?.callbacks.cameraRunning($0) },
            accessChanged: { [weak self] in self?.callbacks.accessChanged() },
            phaseChanged: { [weak self] phase in
                self?.activities.reconcile()
                self?.callbacks.phaseChanged(phase)
            }, presenting: { [weak self] in self?.activities.setPresenting($0) },
            environmentChanged: { [weak self] in self?.activities.reconcile() },
            makeAdditionalService: { [unowned self] _ in try self.callbacks.makeLockScreenService() }))

    public init(preferences: PreferenceStore, files: ApplicationFiles, mediaScript: URL,
                mediaFramework: URL, callbacks: Callbacks) {
        self.preferences = preferences; self.files = files
        self.mediaScript = mediaScript; self.mediaFramework = mediaFramework; self.callbacks = callbacks
    }

    public func start() {
        guard !active else { return }
        active = true
        activities.start()
        runtime.start()
    }
    public func stop() {
        guard active else { return }
        active = false
        runtime.stop()
        activities.stop()
    }
    public func refresh() {
        guard active else { return }
        activities.refreshPreferences()
        runtime.refresh()
    }
    public func toggle() { guard active else { return }; runtime.toggle() }
    public func collapse() { guard active else { return }; runtime.collapse() }
    public func setOverflowCount(_ count: Int) { guard active else { return }; activities.setOverflowCount(count) }
    public func startTimer(minutes: Int) throws {
        guard active, [1, 5, 10, 25].contains(minutes) else { return }
        try activities.timers.start(duration: TimeInterval(minutes * 60), label: "\(minutes)m")
    }
    public func cancelAllTimers() { guard active else { return }; activities.timers.cancelAll() }
    public var timerCount: Int { active ? activities.timers.timers.count : 0 }
    public func clearClipboardHistory() async throws { try await runtime.clearClipboardHistory() }
    public func setClipboardPersistence(_ enabled: Bool) async throws { try await runtime.setClipboardPersistence(enabled) }
    public func adjustVolume(by delta: Float) async -> Bool { await runtime.adjustVolume(by: delta) }
    public func toggleMute() async -> Bool { await runtime.toggleMute() }
}
