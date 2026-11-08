import AppKit
import FluxCore
import FluxPlatform

public enum ApplicationSessionError: Error { case invalidBundle, anotherInstance, storageUnavailable }

/// Startup and shutdown only. The application owner starts features after
/// this transaction. It must stop them before calling finish().
@MainActor
public final class ApplicationSession {
    public static let domain = "com.flux.menubar"
    private static let openKey = "flux.native.sessionOpen.v1"
    private static let cameraKey = "flux.native.cameraRunning.v1"
    public let files: ApplicationFiles
    public let preferences: PreferenceStore
    public let usage: UsageCollection
    public let version: ApplicationVersion
    public let previousSessionWasUnclean: Bool
    public let previousCameraWasRunning: Bool
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let receipt: UpdateLaunch?
    private let lease: SingleInstanceLease
    private var ready = false
    private var finished = false

    public init(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments,
                defaults: UserDefaults = .standard) throws {
        guard bundle.bundleIdentifier == Self.domain, bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "FluxProbeOnly") as? Bool != true else {
            throw ApplicationSessionError.invalidBundle
        }
        // Keep the installed updater's started receipt ahead of all app work.
        let receipt = UpdateLaunch(arguments: arguments, temporaryDirectory: FileManager.default.temporaryDirectory)
        try receipt?.write(phase: .started, processIdentifier: getpid(), bundleURL: bundle.bundleURL)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.domain).contains(where: {
            $0.processIdentifier != getpid() && !$0.isTerminated
        }) else { throw ApplicationSessionError.anotherInstance }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ApplicationSessionError.storageUnavailable
        }
        let files = ApplicationFiles(applicationSupport: support)
        let evidence = InstallationEvidence(hasExistingData: files.hasExistingData, isUpdateLaunch: receipt != nil)
        let lease = try SingleInstanceLease(directory: files.root)
        self.defaults = defaults
        self.bundle = bundle
        self.receipt = receipt
        self.files = files
        self.lease = lease
        preferences = PreferenceStore(defaults: defaults, domain: Self.domain, evidence: evidence)
        version = ApplicationVersion(bundle: bundle)
        previousSessionWasUnclean = defaults.object(forKey: Self.openKey) as? Bool == true
        previousCameraWasRunning = defaults.object(forKey: Self.cameraKey) as? Bool == true
        defaults.set(true, forKey: Self.openKey)
        defaults.set(false, forKey: Self.cameraKey)
        usage = UsageCollection(defaults: defaults)
    }

    /// Call after the status item, shortcuts and feature owners are usable.
    /// Analytics starts only after the updater has its ready receipt.
    public func markReady() throws {
        guard !ready, !finished else { return }
        try receipt?.write(phase: .ready, processIdentifier: getpid(), bundleURL: bundle.bundleURL)
        ready = true
        usage.start()
        usage.record(.launched)
    }

    public func cameraIsRunning(_ running: Bool) {
        guard !finished else { return }
        defaults.set(running, forKey: Self.cameraKey)
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        usage.flush()
        defaults.set(false, forKey: Self.cameraKey)
        defaults.set(false, forKey: Self.openKey)
    }
}
