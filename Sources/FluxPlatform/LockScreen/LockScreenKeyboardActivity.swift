import CoreGraphics
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
        public static let defaultSettlingGrace: TimeInterval = 0.15

        private let armedAtUptime: TimeInterval
        private let settlingGrace: TimeInterval
        private var baselineKeyDownUptime: TimeInterval

        public init(uptime: TimeInterval,
                    initialSecondsSinceKeyDown: TimeInterval,
                    settlingGrace: TimeInterval = Detector.defaultSettlingGrace) {
            armedAtUptime = uptime
            self.settlingGrace = max(0, settlingGrace)
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
