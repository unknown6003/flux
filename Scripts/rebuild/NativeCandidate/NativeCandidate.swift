import AppKit
import FluxApplication
import FluxCore
import FluxPlatform
import FluxUI
import OSLog

/// A runnable integration candidate. The release builder still selects Flux.
/// This entry requires its own candidate-marked bundle and cannot turn an
/// unverified private OS interface into an available capability.
@main struct NativeCandidate {
    @MainActor static func main() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["FluxNativeApp"] as? Bool == true || info["FluxNativeCandidate"] as? Bool == true else { exit(78) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NativeCandidateDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class NativeCandidateDelegate: NSObject, NSApplicationDelegate {
    private var host: ApplicationHost?
    private var terminating = false
    private var terminationReplied = false
    private var terminationDeadline: Timer?
    private var capture: NativeCandidateMenuCapture?
    private let logger = Logger(subsystem: "com.flux.menubar", category: "native-candidate")

    func applicationDidFinishLaunching(_ notification: Notification) {
#if FLUX_PERFORMANCE_TRACE
        do { try beginPerformanceTraceIfRequested() }
        catch {
            logger.error("native.trace.configuration.failed")
            NSApp.terminate(nil)
            return
        }
#endif
        do {
            let session = try ApplicationSession()
            let hider = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? PerApplicationHider() : nil
            let support = PositionMenuBarHidingSupport.current(hider: hider)
            let menu = PositionMenuBarService(defaults: .standard, domain: ApplicationSession.domain,
                preferences: session.preferences, hidingSupport: support, perApplicationHider: hider)
            // The 0.21.35 SkyLight space. Settings reports unavailable only
            // when that private bridge does not load.
            let lock = NativeLockScreenService(preferences: session.preferences)
            let owner = ApplicationHost(session: session, menuBar: menu, lockScreen: lock,
                failure: { [weak self] failure in self?.record(failure) },
                quit: { NativeCandidateDelegate.requestTermination() })
            host = owner
            try owner.start()
            // Release probe: quit from inside a main-actor Task, the same
            // path the updater takes after its hand-off.
            if let raw = ProcessInfo.processInfo.environment["FLUX_PROBE_QUIT_FROM_TASK_AFTER"], let delay = Double(raw) {
                // FLUX_PROBE_QUIT_DIRECT=1 is the control: the 0.22.1 direct call,
                // which only the terminate deadline can finish.
                let direct = ProcessInfo.processInfo.environment["FLUX_PROBE_QUIT_DIRECT"] == "1"
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    if direct { NSApp.terminate(nil) } else { NativeCandidateDelegate.requestTermination() }
                }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--capture-menu-dir"), index + 1 < CommandLine.arguments.count {
                capture = try NativeCandidateMenuCapture(output: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            }
            if CommandLine.arguments.contains("--settings") { owner.showSettings() }
        } catch ApplicationSessionError.anotherInstance {
            NSApp.terminate(nil)
        } catch {
            logger.error("native.startup.failed")
            let alert = NSAlert()
            alert.messageText = "Flux could not start."
            alert.informativeText = "Your saved data was kept. Quit Flux and try again."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        host?.showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host else {
#if FLUX_PERFORMANCE_TRACE
            finishPerformanceTrace()
#endif
            return .terminateNow
        }
        guard !terminating else { return .terminateCancel }
        terminating = true
        capture?.stop(); capture = nil
        // If clean-up cannot run (for example a caller terminated from inside
        // a main-queue job), quit anyway. A run-loop timer still fires in the
        // terminate-later loop when the main queue is blocked.
        let deadline = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logger.error("native.terminate.deadline")
                self?.finishTermination(sender)
            }
        }
        RunLoop.main.add(deadline, forMode: .common)
        terminationDeadline = deadline
        Task { @MainActor in
            await host.stop()
            self.host = nil
#if FLUX_PERFORMANCE_TRACE
            self.finishPerformanceTrace()
#endif
            self.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        terminationDeadline?.invalidate(); terminationDeadline = nil
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// Terminate from the run loop, never from inside a main-queue job.
    /// AppKit's terminate-later loop cannot drain the main queue while a
    /// main-queue job, such as a main-actor Task, is still on the stack. The
    /// updater quits from such a Task, and 0.22.0 and 0.22.1 hung there.
    static func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

#if FLUX_PERFORMANCE_TRACE
    private enum TraceConfigurationFailure: Error { case invalid }

    private func beginPerformanceTraceIfRequested() throws {
        let arguments = CommandLine.arguments
        let flag = "--performance-trace-dir"
        let requested = arguments.contains(flag)
            || ProcessInfo.processInfo.environment["FLUX_ALLOW_PERFORMANCE_TRACE"] == "1"
        guard requested else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "FluxPerformanceTraceCandidate") as? Bool == true,
              ProcessInfo.processInfo.environment["FLUX_ALLOW_PERFORMANCE_TRACE"] == "1",
              arguments.filter({ $0 == flag }).count == 1,
              let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            throw TraceConfigurationFailure.invalid
        }
        try PerformanceTrace.begin(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    }

    private func finishPerformanceTrace() {
        PerformanceTrace.record(.appStop)
        do { _ = try PerformanceTrace.finish() }
        catch { logger.error("native.trace.write.failed") }
    }
#endif

    private func record(_ failure: ApplicationFailure) {
        let code: String = switch failure {
        case .settings: "native.settings.failed"
        case .runtime: "native.feature.failed"
        case .menuBarRecovery: "native.menu.recovery"
        case .timer: "native.timer.failed"
        case .link: "native.link.failed"
        }
        logger.error("\(code, privacy: .public)")
    }
}
