import Foundation
import ServiceManagement

/// Wraps `SMAppService` (macOS 13+) for launch-at-login. This is the modern,
/// sanctioned API — no helper bundle, no deprecated `LSSharedFileList`. It only
/// works from a properly bundled, signed `.app`; the running-from-CLI case is
/// handled gracefully so dev builds don't crash.
@MainActor
enum LoginItemManager {
    /// SMAppService.mainApp can register the process that is currently
    /// running. For a SwiftPM/debug launch that process is a bare executable,
    /// so macOS starts it through Terminal at login. Only a real app bundle
    /// may own Flux's login item.
    static var isBundledApplication: Bool {
        let bundle = Bundle.main
        return bundle.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && bundle.bundleIdentifier == "com.flux.menubar"
    }

    static var isEnabled: Bool {
        guard isBundledApplication else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private static let registrationMigrationKey = "flux.loginItem.bundleRegistration.v1"

    /// Sync the registration to the desired state. Returns the resulting truth so
    /// the UI can correct itself if the OS rejected the change (e.g. the user
    /// disabled it in System Settings › General › Login Items).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isBundledApplication else {
            // The bundled-app migration below owns cleanup of any legacy
            // registration. A bare executable cannot prove which registered
            // service `SMAppService.mainApp` refers to, so it must never
            // unregister the user's packaged Flux.app from this path.
            Log.login.error("Ignoring login-item change from an unbundled executable; launch Flux.app to manage autostart")
            return false
        }

        do {
            migrateLegacyRegistrationIfNeeded()
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Log.login.info("Login item set to \(enabled). Status=\(String(describing: SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.login.error("Login item update failed: \(error.localizedDescription)")
        }
        return isEnabled
    }

    /// A previous debug build could have registered a bare executable under
    /// the same app identity. Clear that registration once from the bundled
    /// app before applying the user's preference, so upgrading stops opening
    /// Terminal windows as well as preventing new ones.
    private static func migrateLegacyRegistrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: registrationMigrationKey) else { return }
        var migrationSucceeded = true
        if SMAppService.mainApp.status == .enabled {
            do {
                try SMAppService.mainApp.unregister()
                Log.login.notice("Removed the legacy unbundled login-item registration")
            } catch {
                migrationSucceeded = false
                Log.login.error("Could not remove the legacy login-item registration: \(error.localizedDescription)")
            }
        }
        if migrationSucceeded {
            defaults.set(true, forKey: registrationMigrationKey)
        }
    }
}
