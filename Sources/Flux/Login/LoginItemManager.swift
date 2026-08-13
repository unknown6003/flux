import Foundation
import ServiceManagement

/// Wraps `SMAppService` (macOS 13+) for launch-at-login. This is the modern,
/// sanctioned API — no helper bundle, no deprecated `LSSharedFileList`. It only
/// works from a properly bundled, signed `.app`; the running-from-CLI case is
/// handled gracefully so dev builds don't crash.
@MainActor
enum LoginItemManager {
    /// Only a bundled app can be a real login item. Registering the SwiftPM
    /// executable from Terminal makes macOS reopen the shell command through
    /// Terminal at login.
    static var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Sync the registration to the desired state. Returns the resulting truth so
    /// the UI can correct itself if the OS rejected the change (e.g. the user
    /// disabled it in System Settings › General › Login Items).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isRunningFromApplicationBundle else {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            Log.login.warning("Ignoring launch-at-login request from an unbundled executable")
            return false
        }
        do {
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
}
