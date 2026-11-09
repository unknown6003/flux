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
                quit: { NSApp.terminate(nil) })
            host = owner
            try owner.start()
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
        Task { @MainActor in
            await host.stop()
            self.host = nil
#if FLUX_PERFORMANCE_TRACE
            self.finishPerformanceTrace()
#endif
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
