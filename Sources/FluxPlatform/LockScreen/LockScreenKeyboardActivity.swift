import CoreGraphics
import Darwin
import Dispatch
import Foundation

/// Detects keyboard activity on the lock screen without reading keycodes,
/// text, or requiring Accessibility or Input Monitoring permissions.
///
/// On macOS 27's lock screen, `CGEventSourceSecondsSinceLastEventType` is quantized
/// to whole-second boundaries (`floor(t)`), which introduces up to a 1-second delay.
/// Meanwhile, `loginwindow` hides the system cursor ~7 ms after the first password
/// keystroke (`SLSCursorIsVisible` transitions `true -> false`). Tracking both signals
/// triggers within ~10–17 ms while preserving key-down age as a fallback if the cursor
/// was already hidden before locking.
public enum LockScreenKeyboardActivity {
    /// Seconds elapsed since the last hardware key-down event.
    public static func secondsSinceLastKeyDown() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Reads whether the system cursor is currently visible via SkyLight's dynamic
    /// `SLSCursorIsVisible` symbol (`() -> Int32`, verified on macOS 27 arm64e).
    /// Returns `nil` if SkyLight or the symbol cannot be loaded.
    @MainActor
    public static func isCursorVisible() -> Bool? {
        SkyLightCursorVisibility.isVisible()
    }

    /// Monotonic-timestamp and cursor-hide tracker that ignores the lock shortcut
    /// or wake key (for example Cmd+Ctrl+Q or Space to wake) and fires once a new
    /// key-down or password-typing cursor hide occurs.
    public struct Detector: Sendable {
        /// Absorbs Mach and CoreGraphics clock rounding jitter between samples.
        public static let advanceTolerance: TimeInterval = 0.05
        /// Ignores events whose timestamp falls within this window after arming
        /// when locked via a keyboard shortcut or wake key.
        public static let defaultSettlingGrace: TimeInterval = 0.12
        /// Minimum settling window for cursor-hide edges right after lock arming.
        public static let minimumCursorSettlingGrace: TimeInterval = 0.05

        private let armedAtUptime: TimeInterval
        private let settlingGrace: TimeInterval
        private let cursorSettlingGrace: TimeInterval
        private var baselineKeyDownUptime: TimeInterval
        private var lastSecondsSinceKeyDown: TimeInterval?
        private var lastCursorVisible: Bool?

        public init(uptime: TimeInterval,
                    initialSecondsSinceKeyDown: TimeInterval,
                    initialCursorVisible: Bool? = nil,
                    settlingGrace: TimeInterval? = nil) {
            armedAtUptime = uptime
            let resolvedGrace = settlingGrace ?? (
                initialSecondsSinceKeyDown.isFinite && initialSecondsSinceKeyDown >= 0 && initialSecondsSinceKeyDown < 0.5
                    ? Detector.defaultSettlingGrace
                    : 0
            )
            self.settlingGrace = max(0, resolvedGrace)
            self.cursorSettlingGrace = settlingGrace.map { max(0, $0) }
                ?? max(self.settlingGrace, Self.minimumCursorSettlingGrace)
            baselineKeyDownUptime = Self.keyDownUptime(
                uptime: uptime,
                secondsSinceKeyDown: initialSecondsSinceKeyDown
            ) ?? uptime
            if initialSecondsSinceKeyDown.isFinite && initialSecondsSinceKeyDown >= 0 {
                lastSecondsSinceKeyDown = initialSecondsSinceKeyDown
            }
            lastCursorVisible = initialCursorVisible
        }

        /// Returns true when a genuinely new key-down or post-settling cursor hide occurred.
        public mutating func recordSample(uptime: TimeInterval,
                                          secondsSinceKeyDown: TimeInterval,
                                          cursorVisible: Bool? = nil) -> Bool {
            let cursorSettled = !uptime.isFinite || (uptime - armedAtUptime >= cursorSettlingGrace)
            let previousCursor = lastCursorVisible
            if let cursorVisible {
                lastCursorVisible = cursorVisible
            }
            if cursorSettled, previousCursor == true, cursorVisible == false {
                return true
            }
            guard let keyDownAt = Self.keyDownUptime(
                uptime: uptime,
                secondsSinceKeyDown: secondsSinceKeyDown
            ) else {
                return false
            }
            let previousAge = lastSecondsSinceKeyDown
            lastSecondsSinceKeyDown = secondsSinceKeyDown
            // Reject a frozen 0.0 plateau across consecutive polls without breaking
            // detection after a delayed poll where idle age grew past previousAge.
            if previousAge == 0, secondsSinceKeyDown == 0 {
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

@MainActor
private enum SkyLightCursorVisibility {
    private typealias CursorIsVisibleFn = @convention(c) () -> Int32

    private static let resolved: CursorIsVisibleFn? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, "SLSCursorIsVisible") else {
            dlclose(handle)
            return nil
        }
        return unsafeBitCast(sym, to: CursorIsVisibleFn.self)
    }()

    static func isVisible() -> Bool? {
        guard let fn = resolved else { return nil }
        return fn() != 0
    }
}

/// Strict, non-coalesced lock-screen keyboard monitor. Uses a strict main-queue
/// `DispatchSourceTimer` plus a short-lived `ProcessInfo` activity token (allowing
/// idle sleep) so App Nap never delays the first password keystroke. Stops immediately
/// once typing is detected or the screen unlocks/sleeps.
@MainActor
public final class LockScreenKeyboardMonitor {
    // Accessed only on MainActor during normal use, and in deinit after all references are gone.
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var activityToken: NSObjectProtocol?
    private var detector: LockScreenKeyboardActivity.Detector
    private let readSystemUptime: @MainActor () -> TimeInterval
    private let readSecondsSinceKeyDown: @MainActor () -> TimeInterval
    private let readCursorVisible: @MainActor () -> Bool?
    private let onKeyActivity: @MainActor () -> Void

    public var isRunning: Bool { timer != nil }

    public init(pollInterval: Duration = .milliseconds(10),
                settlingGrace: TimeInterval? = nil,
                readSystemUptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                readSecondsSinceKeyDown: @escaping @MainActor () -> TimeInterval = LockScreenKeyboardActivity.secondsSinceLastKeyDown,
                readCursorVisible: @escaping @MainActor () -> Bool? = LockScreenKeyboardActivity.isCursorVisible,
                onKeyActivity: @escaping @MainActor () -> Void) {
        self.readSystemUptime = readSystemUptime
        self.readSecondsSinceKeyDown = readSecondsSinceKeyDown
        self.readCursorVisible = readCursorVisible
        self.onKeyActivity = onKeyActivity
        self.detector = LockScreenKeyboardActivity.Detector(
            uptime: readSystemUptime(),
            initialSecondsSinceKeyDown: readSecondsSinceKeyDown(),
            initialCursorVisible: readCursorVisible(),
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
            leeway: .milliseconds(1)
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
                                 secondsSinceKeyDown: readSecondsSinceKeyDown(),
                                 cursorVisible: readCursorVisible()) {
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
