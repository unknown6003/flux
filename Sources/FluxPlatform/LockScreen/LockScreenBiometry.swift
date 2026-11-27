import Foundation
import LocalAuthentication
import OSLog
import notify

/// Current biometric unlock availability reported by macOS LocalAuthentication.
public enum LockScreenBiometryState: Equatable, Sendable {
    /// Touch ID / biometrics can unlock the Mac right now.
    case ready
    /// macOS locked out biometrics (48-hour token expiry, reboot, failed attempts, etc.)
    /// and requires password entry to unlock and re-enable Touch ID.
    case lockedOut
    /// Biometrics are unavailable or not enrolled (no sensor, clamshell, or disabled).
    case unavailable
}

/// Non-prompting LocalAuthentication state lookup for the lock screen.
public enum LockScreenBiometry {
    public static func currentState() -> LockScreenBiometryState {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return classify(canEvaluate: canEvaluate, errorDomain: error?.domain, errorCode: error?.code)
    }

    static func classify(canEvaluate: Bool, errorDomain: String?, errorCode: Int?) -> LockScreenBiometryState {
        if canEvaluate { return .ready }
        if errorDomain == LAError.errorDomain, errorCode == LAError.Code.biometryLockout.rawValue {
            return .lockedOut
        }
        return .unavailable
    }
}

/// Watches macOS's Darwin biometric lockout notification while locked so Flux
/// immediately yields the full-screen backdrop if Touch ID becomes locked out mid-lock.
@MainActor
public final class BiometryLockoutObserver {
    public static let defaultNotificationName = "com.apple.BiometricKit.generalLockoutStateChanged"
    private static let logger = Logger(subsystem: "com.flux.menubar", category: "lockscreen")

    // Accessed only on MainActor during normal use, and in deinit after all references are gone.
    private nonisolated(unsafe) var token: Int32 = NOTIFY_TOKEN_INVALID

    public var isRegistered: Bool { token != NOTIFY_TOKEN_INVALID }

    public init(notificationName: String = BiometryLockoutObserver.defaultNotificationName,
                onChange: @escaping @MainActor @Sendable () -> Void) {
        var registered: Int32 = NOTIFY_TOKEN_INVALID
        // Keep queue pinned to DispatchQueue.main so MainActor.assumeIsolated is sound.
        let status = notify_register_dispatch(
            notificationName,
            &registered,
            DispatchQueue.main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        if status == NOTIFY_STATUS_OK {
            token = registered
        } else {
            Self.logger.error("lock.biometryObserver.registerFailed status=\(status, privacy: .public)")
        }
    }

    public func stop() {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID {
            notify_cancel(token)
        }
    }
}
