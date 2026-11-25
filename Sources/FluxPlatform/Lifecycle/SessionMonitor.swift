import AppKit
import FluxCore

private final class DistributedObservation: NSObject, @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let receive: @Sendable () -> Void

    init(center: DistributedNotificationCenter, name: Notification.Name,
         receive: @escaping @Sendable () -> Void) {
        self.center = center
        self.receive = receive
        super.init()
        center.addObserver(self,
                           selector: #selector(handle(_:)),
                           name: name,
                           object: nil,
                           suspensionBehavior: .deliverImmediately)
    }

    @objc private func handle(_ notification: Notification) {
        let callback = receive
        if Thread.isMainThread {
            callback()
        } else {
            DispatchQueue.main.async {
                callback()
            }
        }
    }

    deinit { center.removeObserver(self) }
}

/// One owner routes session transitions. Unavailable or malformed session data
/// pauses private-content services until a fresh known state.
/// The two distributed lock notifications and dictionary key are empirical
/// macOS interfaces. They need signed hardware checks on each supported OS.
@MainActor public final class SessionMonitor {
    static let defaultUnlockRecheckDelays: [Duration] = [
        .milliseconds(20), .milliseconds(40), .milliseconds(80),
        .milliseconds(160), .milliseconds(320), .milliseconds(640),
    ]
    static let defaultLockedReconcileInterval: Duration = .seconds(2)

    public private(set) var phase: SessionPhase
    private var onPhase: ((SessionPhase) -> Void)?
    private var onEnvironmentChange: (() -> Void)?
    private let readPhase: @MainActor () -> SessionPhase
    private let unlockRecheckDelays: [Duration]
    private let lockedReconcileInterval: Duration?
    private var observations: [NotificationObservation] = []
    private var distributed: [DistributedObservation] = []
    private var unlockRecheckTask: Task<Void, Never>?
    private var lockedReconcileTask: Task<Void, Never>?
    private var active = true

    var hasActiveReconciliationTasks: Bool {
        unlockRecheckTask != nil || lockedReconcileTask != nil
    }

    public convenience init(onPhase: @escaping (SessionPhase) -> Void,
                            onEnvironmentChange: @escaping () -> Void) {
        self.init(workspace: NSWorkspace.shared.notificationCenter, application: .default,
                  distributed: .default(), readPhase: Self.currentPhase,
                  onPhase: onPhase, onEnvironmentChange: onEnvironmentChange)
    }

    init(workspace: NotificationCenter, application: NotificationCenter,
         distributed center: DistributedNotificationCenter?, readPhase: @escaping @MainActor () -> SessionPhase,
         unlockRecheckDelays: [Duration] = SessionMonitor.defaultUnlockRecheckDelays,
         lockedReconcileInterval: Duration? = SessionMonitor.defaultLockedReconcileInterval,
         onPhase: @escaping (SessionPhase) -> Void, onEnvironmentChange: @escaping () -> Void) {
        self.readPhase = readPhase
        self.unlockRecheckDelays = unlockRecheckDelays
        self.lockedReconcileInterval = lockedReconcileInterval
        phase = readPhase()
        self.onPhase = onPhase
        self.onEnvironmentChange = onEnvironmentChange
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { owner in
#if FLUX_PERFORMANCE_TRACE
                PerformanceTrace.record(.sessionSleep)
#endif
                owner.setPhase(.sleeping)
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { owner in
#if FLUX_PERFORMANCE_TRACE
                PerformanceTrace.record(.sessionWake)
#endif
                owner.reconcilePotentialUnlock()
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.sessionLock)
#endif
            owner.handleScreenLockedNotification()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.spaceChanged)
#endif
            owner.onEnvironmentChange?()
        }
        observe(application, NSApplication.didChangeScreenParametersNotification) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.displayChanged)
#endif
            owner.onEnvironmentChange?()
        }
        observe(application, .NSSystemTimeZoneDidChange) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.timeZoneChanged)
#endif
            owner.onEnvironmentChange?()
        }
        observe(application, .NSSystemClockDidChange) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.clockChanged)
#endif
            owner.onEnvironmentChange?()
        }
        observe(application, NSApplication.didBecomeActiveNotification) { owner in
#if FLUX_PERFORMANCE_TRACE
            PerformanceTrace.record(.applicationActivated)
#endif
            owner.reconcilePotentialUnlock()
        }
        if let center {
            distributed = [
                DistributedObservation(center: center, name: .init("com.apple.screenIsLocked")) { [weak self] in
                    // Delivered on main thread immediately; run synchronously to avoid a run-loop frame delay.
                    MainActor.assumeIsolated {
#if FLUX_PERFORMANCE_TRACE
                        PerformanceTrace.record(.sessionLock)
#endif
                        self?.handleScreenLockedNotification()
                    }
                },
                DistributedObservation(center: center, name: .init("com.apple.screenIsUnlocked")) { [weak self] in
                    MainActor.assumeIsolated {
#if FLUX_PERFORMANCE_TRACE
                        PerformanceTrace.record(.sessionUnlock)
#endif
                        self?.handleScreenUnlockedNotification()
                    }
                },
            ]
        }
        syncLockedReconciliation()
    }

    deinit {
        unlockRecheckTask?.cancel()
        lockedReconcileTask?.cancel()
    }

    func handleScreenLockedNotification() {
        guard active else { return }
        cancelUnlockRecheck()
        cancelLockedReconciliation()
        setPhase(.locked)
    }

    func handleScreenUnlockedNotification() {
        guard active else { return }
        reconcilePotentialUnlock()
    }

    public func refresh() {
        guard active else { return }
#if FLUX_PERFORMANCE_TRACE
        PerformanceTrace.record(.sessionRefresh)
#endif
        setPhase(readPhase())
    }

    public func stop() {
        active = false
        cancelUnlockRecheck()
        cancelLockedReconciliation()
        observations.removeAll()
        distributed.removeAll()
        onPhase = nil
        onEnvironmentChange = nil
    }

    private func reconcilePotentialUnlock() {
        guard active else { return }
        setPhase(readPhase())
        if active {
            onEnvironmentChange?()
        }
        if active, phase == .locked {
            scheduleUnlockRecheck()
        }
    }

    private func reconcileLockedPhase() -> Bool {
        guard active, phase == .locked else { return true }
        let next = readPhase()
        guard next != phase else { return false }
        setPhase(next)
        if active { onEnvironmentChange?() }
        return true
    }

    private func setPhase(_ phase: SessionPhase) {
        guard active else { return }
        if phase != .locked {
            cancelUnlockRecheck()
            cancelLockedReconciliation()
        }
        guard self.phase != phase else {
            syncLockedReconciliation()
            return
        }
#if FLUX_PERFORMANCE_TRACE
        PerformanceTrace.record(.phaseChanged)
#endif
        self.phase = phase
        onPhase?(phase)
        syncLockedReconciliation()
    }

    private func scheduleUnlockRecheck() {
        cancelUnlockRecheck()
        guard active, phase == .locked, !unlockRecheckDelays.isEmpty else { return }
        let delays = unlockRecheckDelays
        unlockRecheckTask = Task { @MainActor [weak self] in
            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if self.reconcileLockedPhase() { return }
            }
            if let self, !Task.isCancelled {
                self.unlockRecheckTask = nil
            }
        }
    }

    private func cancelUnlockRecheck() {
        unlockRecheckTask?.cancel()
        unlockRecheckTask = nil
    }

    private func syncLockedReconciliation() {
        guard active, phase == .locked, let interval = lockedReconcileInterval else {
            cancelLockedReconciliation()
            return
        }
        guard lockedReconcileTask == nil else { return }
        lockedReconcileTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if self.reconcileLockedPhase() { return }
            }
        }
    }

    private func cancelLockedReconciliation() {
        lockedReconcileTask?.cancel()
        lockedReconcileTask = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (SessionMonitor) -> Void) {
        observations.append(NotificationObservation(center: center, name: name) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                action(self)
            }
        })
    }

    private static func currentPhase() -> SessionPhase {
        phase(from: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func phase(from session: [String: Any]?) -> SessionPhase {
        guard let session,
              let onConsole = session[kCGSessionOnConsoleKey as String] as? NSNumber,
              CFGetTypeID(onConsole) == CFBooleanGetTypeID(), onConsole.boolValue else { return .locked }
        // macOS 27 omits this key in the observed active, unlocked session.
        // A present key must be a Boolean. The lock notifications pause work
        // even if a subsequent dictionary read fails or changes its schema.
        guard let raw = session["CGSSessionScreenIsLocked"] else { return .unlocked }
        guard let locked = raw as? NSNumber, CFGetTypeID(locked) == CFBooleanGetTypeID() else { return .locked }
        return locked.boolValue ? .locked : .unlocked
    }
}
