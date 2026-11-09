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
        guard Bundle.main.object(forInfoDictionaryKey: "FluxNativeCandidate") as? Bool == true else { exit(78) }
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
        do {
            let session = try ApplicationSession()
            let support: PositionMenuBarHidingSupport = ProcessInfo.processInfo.environment[
                "FLUX_ALLOW_UNVERIFIED_POSITION_BACKEND"] == "1" ? .byPosition : .unverified
            let menu = PositionMenuBarService(defaults: .standard, domain: ApplicationSession.domain,
                preferences: session.preferences, hidingSupport: support)
            // No verified private bridge is linked into this candidate. The
            // saved choice is preserved and Settings reports unavailable.
            let lock = NativeLockScreenService(preferences: session.preferences,
                availability: { .unavailable }, makeBridge: { throw LockScreenServiceError.unavailable })
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
        guard let host else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        capture?.stop(); capture = nil
        Task { @MainActor in
            await host.stop()
            self.host = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

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
