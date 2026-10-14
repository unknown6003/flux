import AppKit
import ApplicationServices

/// The trust flag can stay false after a grant in a running macOS 27 process.
/// A successful protected AX read proves that the current process has access.
enum AccessibilityAccess {
    static func isGranted() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder").first
            ?? NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systemuiserver").first else { return false }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.2)
        var children: CFTypeRef?
        return AXUIElementCopyAttributeValue(owner, kAXChildrenAttribute as CFString,
                                            &children) == .success
    }
}
