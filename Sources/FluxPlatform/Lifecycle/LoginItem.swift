import Foundation
import ServiceManagement

public enum LoginItemState: Equatable, Sendable { case disabled, enabled, needsApproval, unavailable }
public enum LoginItemError: Error { case notInstalled }

/// Reads the system state. It never registers from construction or refresh.
@MainActor public enum LoginItem {
    public static var isInstalledApplication: Bool {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "com.flux.menubar",
              bundle.bundleURL.pathExtension == "app",
              !bundle.bundleURL.path.hasPrefix("/Volumes/"),
              !bundle.bundleURL.path.contains("/AppTranslocation/") else { return false }
        return true
    }

    public static var state: LoginItemState {
        guard isInstalledApplication else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Call only from the user's switch action. The caller saves and displays
    /// the fresh system result, including approval that must happen in Settings.
    public static func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        guard isInstalledApplication else { throw LoginItemError.notInstalled }
        if enabled {
            if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
        return state
    }

    public static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
