import AppKit
import FluxCore

private final class DistributedObservation: @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let token: any NSObjectProtocol

    init(center: DistributedNotificationCenter, name: Notification.Name,
         receive: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: receive)
    }

    deinit { center.removeObserver(token) }
}

/// One owner routes session transitions. Unavailable or malformed session data
/// pauses private-content services until a fresh known state.
/// The two distributed lock notifications and dictionary key are empirical
/// macOS interfaces. They need signed hardware checks on each supported OS.
@MainActor public final class SessionMonitor {
    public private(set) var phase: SessionPhase
    private var onPhase: ((SessionPhase) -> Void)?
    private var onEnvironmentChange: (() -> Void)?
    private let readPhase: @MainActor () -> SessionPhase
    private var observations: [NotificationObservation] = []
    private var distributed: [DistributedObservation] = []
    private var active = true

    public convenience init(onPhase: @escaping (SessionPhase) -> Void,
                            onEnvironmentChange: @escaping () -> Void) {
        self.init(workspace: NSWorkspace.shared.notificationCenter, application: .default,
                  distributed: .default(), readPhase: Self.currentPhase,
                  onPhase: onPhase, onEnvironmentChange: onEnvironmentChange)
    }

    init(workspace: NotificationCenter, application: NotificationCenter,
         distributed center: DistributedNotificationCenter?, readPhase: @escaping @MainActor () -> SessionPhase,
         onPhase: @escaping (SessionPhase) -> Void, onEnvironmentChange: @escaping () -> Void) {
        self.readPhase = readPhase
        phase = readPhase()
        self.onPhase = onPhase
        self.onEnvironmentChange = onEnvironmentChange
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { $0.setPhase(.sleeping) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { owner in
                owner.setPhase(owner.readPhase())
                owner.onEnvironmentChange?()
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setPhase(.locked) }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.onEnvironmentChange?() }
        observe(application, NSApplication.didChangeScreenParametersNotification) { $0.onEnvironmentChange?() }
        observe(application, .NSSystemTimeZoneDidChange) { $0.onEnvironmentChange?() }
        if let center {
            distributed = [
                DistributedObservation(center: center, name: .init("com.apple.screenIsLocked")) { [weak self] _ in
                    Task { @MainActor in self?.setPhase(.locked) }
                },
                DistributedObservation(center: center, name: .init("com.apple.screenIsUnlocked")) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.setPhase(self.readPhase())
                        self.onEnvironmentChange?()
                    }
                },
            ]
        }
    }

    public func refresh() {
        guard active else { return }
        setPhase(readPhase())
    }

    public func stop() {
        active = false
        observations.removeAll()
        distributed.removeAll()
        onPhase = nil
        onEnvironmentChange = nil
    }

    private func setPhase(_ phase: SessionPhase) {
        guard active, self.phase != phase else { return }
        self.phase = phase
        onPhase?(phase)
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
