import AppKit
import ApplicationServices
import Darwin

/// macOS can retain a denied access result for a running process. A short-lived
/// copy of this same app reads the current grant without opening any UI.
enum AccessibilityAccess {
    private static let lock = NSLock()
    private static var cached: (time: TimeInterval, granted: Bool)?

    static func exitIfRequested() {
        if CommandLine.arguments.contains("--flux-check-access") {
            exit(AXIsProcessTrusted() ? 0 : 1)
        }
    }

    static func isGranted(forceRefresh: Bool = false) -> Bool {
        if AXIsProcessTrusted() { return true }
        lock.lock()
        let previous = cached
        lock.unlock()
        if !forceRefresh, let previous,
           ProcessInfo.processInfo.systemUptime - previous.time < 0.5 {
            return previous.granted
        }
        let granted = freshGrant()
        lock.lock()
        cached = (ProcessInfo.processInfo.systemUptime, granted)
        lock.unlock()
        return granted
    }

    private static func freshGrant() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--flux-check-access"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            // The flag exits before app startup, so this child has no descendants.
            kill(process.processIdentifier, SIGKILL)
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
