import FluxCore

/// The host needs a session's state and its three lifecycle operations. The
/// production implementation owns the process lease and updater receipt.
@MainActor protocol HostSession: AnyObject {
    var files: ApplicationFiles { get }
    var preferences: PreferenceStore { get }
    var usage: UsageCollection { get }
    var version: ApplicationVersion { get }
    var previousSessionWasUnclean: Bool { get }
    var previousCameraWasRunning: Bool { get }
    func markReady() throws
    func cameraIsRunning(_ running: Bool)
    func finish()
}

extension ApplicationSession: HostSession {}
