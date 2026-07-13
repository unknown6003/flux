import AppKit

/// Restart the running app bundle.
///
/// Some state is only read when the process starts — most notably a status item's
/// saved "Preferred Position", which macOS consults at `NSStatusItem` creation and
/// never re-reads. So resetting the menu-bar layout means starting over, not
/// nudging the live items.
@MainActor
enum Relaunch {
    /// Quit and come back. A running bundle can't relaunch itself directly — the new
    /// instance would race the dying one and macOS would just activate the old
    /// process — so hand the job to a detached `sh` that waits for us to exit first.
    static func now() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this PID to actually be gone, then reopen. `open -n` isn't needed:
        // by the time we're dead there's no instance left to activate.
        task.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; "
            + "open \(shellQuoted(bundlePath))",
        ]
        do {
            try task.run()
        } catch {
            Log.menuBar.error("Relaunch failed to spawn helper: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Single-quote for `sh`, escaping any embedded quote. App bundles live under
    /// paths the user controls, so this can't assume a well-behaved path.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
