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

        // A late wake-key timestamp inside the 150 ms settling window (1000.21) is ignored
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

    @Test func detectorFiresAfterLongIdlePeriodOnceSettled() {
        var detector = LockScreenKeyboardActivity.Detector(
            uptime: 5000.0,
            initialSecondsSinceKeyDown: 1800.0
        )
        let stillIdle = detector.recordSample(uptime: 5000.20, secondsSinceKeyDown: 1800.20)
        let pressedKey = detector.recordSample(uptime: 5000.25, secondsSinceKeyDown: 0.02)
        #expect(!stillIdle)
        #expect(pressedKey)
    }
}
