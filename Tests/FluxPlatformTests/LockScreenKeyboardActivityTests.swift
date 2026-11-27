import Foundation
import Testing
@testable import FluxPlatform

struct LockScreenKeyboardActivityTests {
    @Test func detectorIgnoresLockShortcutSettlingWakeKeyAndJitterRegardlessOfPollSchedule() {
        // User locked with Cmd+Ctrl+Q 130 ms before the lock notification arrived.
        var fastPoll = LockScreenKeyboardActivity.Detector(
            uptime: 1000.13,
            initialSecondsSinceKeyDown: 0.13
        )
        var delayedPoll = LockScreenKeyboardActivity.Detector(
            uptime: 1000.13,
            initialSecondsSinceKeyDown: 0.13
        )

        // A late wake-key timestamp inside the 120 ms settling window (1000.21) is ignored
        // under both an early poll (1000.22) and a delayed poll (1000.40).
        let earlyWakePoll = fastPoll.recordSample(uptime: 1000.22, secondsSinceKeyDown: 0.01)
        let delayedWakePoll = delayedPoll.recordSample(uptime: 1000.40, secondsSinceKeyDown: 0.19)
        #expect(!earlyWakePoll)
        #expect(!delayedWakePoll)

        // After settling, no new keypresses (with small clock jitter).
        let sample1 = fastPoll.recordSample(uptime: 1000.35, secondsSinceKeyDown: 0.14)
        let sample2 = fastPoll.recordSample(uptime: 1000.40, secondsSinceKeyDown: 0.17)
        let sample3 = fastPoll.recordSample(uptime: 1001.50, secondsSinceKeyDown: 1.29)
        #expect(!sample1)
        #expect(!sample2)
        #expect(!sample3)

        // Invalid or unavailable idle values never false-trigger.
        let invalidNegative = fastPoll.recordSample(uptime: 1001.55, secondsSinceKeyDown: -1)
        let invalidNaN = fastPoll.recordSample(uptime: 1001.60, secondsSinceKeyDown: .nan)
        let invalidInfinity = fastPoll.recordSample(uptime: 1001.65, secondsSinceKeyDown: .infinity)
        #expect(!invalidNegative)
        #expect(!invalidNaN)
        #expect(!invalidInfinity)

        // User starts typing password at uptime 1002.00; even if the poll was delayed 1.2s,
        // the new key-down is still detected under both schedules.
        let delayedPollAfterKey = fastPoll.recordSample(uptime: 1003.20, secondsSinceKeyDown: 1.20)
        let immediatePollAfterKey = delayedPoll.recordSample(uptime: 1002.02, secondsSinceKeyDown: 0.02)
        // Repeated polls with the same key-down do not re-fire.
        let repeatedPoll = fastPoll.recordSample(uptime: 1003.25, secondsSinceKeyDown: 1.25)
        #expect(delayedPollAfterKey)
        #expect(immediatePollAfterKey)
        #expect(!repeatedPoll)
    }

    @Test func detectorFiresImmediatelyAfterLongIdlePeriodWithoutSettlingDelay() {
        var detector = LockScreenKeyboardActivity.Detector(
            uptime: 5000.0,
            initialSecondsSinceKeyDown: 1800.0
        )
        let stillIdle = detector.recordSample(uptime: 5000.03, secondsSinceKeyDown: 1800.03)
        // First password character pressed 40 ms after lock (no keyboard lock shortcut active).
        let pressedKey = detector.recordSample(uptime: 5000.05, secondsSinceKeyDown: 0.01)
        #expect(!stillIdle)
        #expect(pressedKey)
    }

    @MainActor private final class ClockState {
        var uptime: TimeInterval
        var lastKeyDownAt: TimeInterval
        var cursorVisible: Bool?
        var triggers = 0

        init(uptime: TimeInterval, lastKeyDownAt: TimeInterval, cursorVisible: Bool? = true) {
            self.uptime = uptime
            self.lastKeyDownAt = lastKeyDownAt
            self.cursorVisible = cursorVisible
        }
    }

    @Test func detectorFiresImmediatelyOnCursorHideWhenKeyDownAgeIsQuantized() {
        // Simulates macOS 27 lock screen where CGEventSource key-down age is quantized
        // to whole-second ticks while loginwindow hides the cursor ~7 ms after key #1.
        var detector = LockScreenKeyboardActivity.Detector(
            uptime: 1000.50,
            initialSecondsSinceKeyDown: 10.0,
            initialCursorVisible: true
        )
        let idleVisible = detector.recordSample(uptime: 1000.55, secondsSinceKeyDown: 10.05, cursorVisible: true)
        #expect(!idleVisible)

        // Key #1 pressed: key-down age hasn't flipped yet, but WindowServer hides cursor.
        let cursorHidden = detector.recordSample(uptime: 1000.57, secondsSinceKeyDown: 10.07, cursorVisible: false)
        #expect(cursorHidden)

        // Cursor staying hidden does not re-fire.
        let stillHidden = detector.recordSample(uptime: 1000.59, secondsSinceKeyDown: 10.09, cursorVisible: false)
        #expect(!stillHidden)

        // A constant quantized 0.0 age plateau never triggers a phantom key-down without a real drop.
        var plateau = LockScreenKeyboardActivity.Detector(
            uptime: 3000.00,
            initialSecondsSinceKeyDown: 0.0,
            initialCursorVisible: true
        )
        let plateauSample1 = plateau.recordSample(uptime: 3000.20, secondsSinceKeyDown: 0.0, cursorVisible: true)
        let plateauSample2 = plateau.recordSample(uptime: 3000.50, secondsSinceKeyDown: 0.0, cursorVisible: true)
        #expect(!plateauSample1)
        #expect(!plateauSample2)

        // If cursor started hidden before lock, moving the mouse (false -> true) never triggers,
        // and typing afterward (true -> false) triggers immediately.
        var startedHidden = LockScreenKeyboardActivity.Detector(
            uptime: 2000.00,
            initialSecondsSinceKeyDown: 5.0,
            initialCursorVisible: false
        )
        let mouseMoved = startedHidden.recordSample(uptime: 2000.20, secondsSinceKeyDown: 5.20, cursorVisible: true)
        let typedAfterMouse = startedHidden.recordSample(uptime: 2000.25, secondsSinceKeyDown: 5.25, cursorVisible: false)
        #expect(!mouseMoved)
        #expect(typedAfterMouse)

        // A cursor hide inside the minimum 50 ms post-arming settling window is ignored.
        var earlyHide = LockScreenKeyboardActivity.Detector(
            uptime: 6000.00,
            initialSecondsSinceKeyDown: 12.0,
            initialCursorVisible: true
        )
        let earlyCursorFlip = earlyHide.recordSample(uptime: 6000.02, secondsSinceKeyDown: 12.02, cursorVisible: false)
        #expect(!earlyCursorFlip)
    }

    @Test @MainActor func strictMonitorFiresOnCursorHideBeforeKeyDownAgeFlips() async throws {
        let clock = ClockState(uptime: 4000.50, lastKeyDownAt: 3990.00, cursorVisible: true)
        let monitor = LockScreenKeyboardMonitor(
            pollInterval: .milliseconds(10),
            readSystemUptime: { clock.uptime },
            readSecondsSinceKeyDown: { max(0, clock.uptime - clock.lastKeyDownAt) },
            readCursorVisible: { clock.cursorVisible },
            onKeyActivity: { clock.triggers += 1 }
        )
        defer { monitor.stop() }
        #expect(monitor.isRunning)

        clock.uptime = 4000.55
        clock.cursorVisible = false
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        while clock.triggers == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.triggers == 1)
        #expect(!monitor.isRunning)
    }

    @Test @MainActor func strictMonitorFiresOnceOnKeyActivityAndStopsCleanly() async throws {
        let clock = ClockState(uptime: 2000.10, lastKeyDownAt: 2000.00, cursorVisible: nil)

        let monitor = LockScreenKeyboardMonitor(
            pollInterval: .milliseconds(10),
            readSystemUptime: { clock.uptime },
            readSecondsSinceKeyDown: { max(0, clock.uptime - clock.lastKeyDownAt) },
            readCursorVisible: { clock.cursorVisible },
            onKeyActivity: { clock.triggers += 1 }
        )
        defer { monitor.stop() }
        #expect(monitor.isRunning)

        // Wait a couple ticks without typing: must stay running and not fire.
        clock.uptime = 2000.20
        try await Task.sleep(for: .milliseconds(35))
        #expect(clock.triggers == 0)
        #expect(monitor.isRunning)

        // Simulate key #1 past settling window: must fire promptly and stop itself.
        clock.uptime = 2000.40
        clock.lastKeyDownAt = 2000.39
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while clock.triggers == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.triggers == 1)
        #expect(!monitor.isRunning)
    }

    @Test @MainActor func stoppedMonitorIgnoresSubsequentKeyActivity() async throws {
        let clock = ClockState(uptime: 3000.00, lastKeyDownAt: 2900.00)

        let monitor = LockScreenKeyboardMonitor(
            pollInterval: .milliseconds(10),
            readSystemUptime: { clock.uptime },
            readSecondsSinceKeyDown: { max(0, clock.uptime - clock.lastKeyDownAt) },
            readCursorVisible: { nil },
            onKeyActivity: { clock.triggers += 1 }
        )
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)

        clock.uptime = 3000.50
        clock.lastKeyDownAt = 3000.49
        try await Task.sleep(for: .milliseconds(40))
        #expect(clock.triggers == 0)
    }
}
