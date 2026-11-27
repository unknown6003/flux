import CoreGraphics
import Dispatch
import Foundation

/// Detects hardware keyboard activity on the lock screen without reading
/// keycodes, text, or requiring Accessibility or Input Monitoring permissions.
public enum LockScreenKeyboardActivity {
    /// Seconds elapsed since the last hardware key-down event.
    public static func secondsSinceLastKeyDown() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Monotonic-timestamp tracker that ignores the lock shortcut or wake key
    /// (for example Cmd+Ctrl+Q or Space to wake) and fires once a new key-down occurs.
    public struct Detector: Sendable {
        /// Absorbs Mach and CoreGraphics clock rounding jitter between samples.
        public static let advanceTolerance: TimeInterval = 0.05
        /// Ignores key-downs whose own timestamp falls within this window after arming
        /// so late HID updates from the lock shortcut or wake key never false-trigger,
        /// regardless of poll timing.
        public static let defaultSettlingGrace: TimeInterval = 0.12

        private let armedAtUptime: TimeInterval
        private let settlingGrace: TimeInterval
        private var baselineKeyDownUptime: TimeInterval

        public init(uptime: TimeInterval,
                    initialSecondsSinceKeyDown: TimeInterval,
                    settlingGrace: TimeInterval? = nil) {
            armedAtUptime = uptime
            let resolvedGrace = settlingGrace ?? (
                initialSecondsSinceKeyDown.isFinite && initialSecondsSinceKeyDown >= 0 && initialSecondsSinceKeyDown < 0.5
                    ? Detector.defaultSettlingGrace
                    : 0
            )
            self.settlingGrace = max(0, resolvedGrace)
            baselineKeyDownUptime = Self.keyDownUptime(
                uptime: uptime,
                secondsSinceKeyDown: initialSecondsSinceKeyDown
            ) ?? uptime
        }

        /// Returns true when a genuinely new key-down occurred after both the
        /// initial baseline and the post-arming settling cutoff.
        public mutating func recordSample(uptime: TimeInterval, secondsSinceKeyDown: TimeInterval) -> Bool {
            guard let keyDownAt = Self.keyDownUptime(
                uptime: uptime,
                secondsSinceKeyDown: secondsSinceKeyDown
            ) else {
                return false
            }
            let cutoff = max(baselineKeyDownUptime + Self.advanceTolerance, armedAtUptime + settlingGrace)
            if keyDownAt > cutoff {
                baselineKeyDownUptime = keyDownAt
                return true
            }
            return false
        }

        private static func keyDownUptime(uptime: TimeInterval, secondsSinceKeyDown: TimeInterval) -> TimeInterval? {
            guard uptime.isFinite, secondsSinceKeyDown.isFinite, secondsSinceKeyDown >= 0 else { return nil }
            return uptime - secondsSinceKeyDown
        }
    }
}

/// Strict, non-coalesced lock-screen keyboard monitor. Uses a strict main-queue
/// `DispatchSourceTimer` plus a short-lived `ProcessInfo` activity token (allowing
/// idle sleep) so App Nap never delays the first password keystroke by hundreds of
/// milliseconds. Stops immediately once typing is detected or the screen unlocks/sleeps.
@MainActor
public final class LockScreenKeyboardMonitor {
    // Accessed only on MainActor during normal use, and in deinit after all references are gone.
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var activityToken: NSObjectProtocol?
    private var detector: LockScreenKeyboardActivity.Detector
    private let readSystemUptime: @MainActor () -> TimeInterval
    private let readSecondsSinceKeyDown: @MainActor () -> TimeInterval
    private let onKeyActivity: @MainActor () -> Void

    public var isRunning: Bool { timer != nil }

    public init(pollInterval: Duration = .milliseconds(20),
                settlingGrace: TimeInterval? = nil,
                readSystemUptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                readSecondsSinceKeyDown: @escaping @MainActor () -> TimeInterval = LockScreenKeyboardActivity.secondsSinceLastKeyDown,
                onKeyActivity: @escaping @MainActor () -> Void) {
        self.readSystemUptime = readSystemUptime
        self.readSecondsSinceKeyDown = readSecondsSinceKeyDown
        self.onKeyActivity = onKeyActivity
        self.detector = LockScreenKeyboardActivity.Detector(
            uptime: readSystemUptime(),
            initialSecondsSinceKeyDown: readSecondsSinceKeyDown(),
            settlingGrace: settlingGrace
        )
        start(pollInterval: pollInterval)
    }

    private func start(pollInterval: Duration) {
        let components = pollInterval.components
        let intervalMs = max(5, Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000))
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Detect lock screen password typing"
        )
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(2)
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer = source
        source.resume()
    }

    private func tick() {
        guard timer != nil else { return }
        if detector.recordSample(uptime: readSystemUptime(),
                                 secondsSinceKeyDown: readSecondsSinceKeyDown()) {
            stop()
            onKeyActivity()
        }
    }

    public func stop() {
        if let source = timer {
            timer = nil
            source.setEventHandler {}
            source.cancel()
        }
        if let token = activityToken {
            activityToken = nil
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    deinit {
        if let source = timer {
            source.setEventHandler {}
            source.cancel()
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
