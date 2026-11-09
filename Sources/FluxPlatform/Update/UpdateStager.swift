import Darwin
import Foundation
import FluxCore

public enum UpdateStageError: Error { case busy, installLocation, stage, notPrepared, helper }

/// A preparation token contains no path supplied by a release response.
/// The owner must hand it off or discard it before another preparation.
public struct PreparedUpdate: Sendable {
    public let token: UUID
    public let version: ReleaseVersion
}

public actor UpdateStager {
    private struct Stage {
        let update: PreparedUpdate
        let workspace: URL
        let mount: URL
        let directory: URL
        let application: URL
        let destination: URL
        let backup: URL
    }
    private let runner = BoundedCommand()
    private let verifier = SignedApplicationVerifier()
    private var prepared: Stage?
    private var manualImage: UpdateImageCache?
    private var busy = false
    public init() {}

    public func prepare(_ release: ReleaseManifest, replacing installURL: URL) async throws -> PreparedUpdate {
        try Task.checkCancellation()
        guard !busy, prepared == nil else { throw UpdateStageError.busy }
        busy = true
        defer { busy = false }
        let manager = FileManager.default
        let destination = installURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        guard destination.isFileURL, destination.pathExtension == "app",
              !destination.path.hasPrefix("/Volumes/"),
              !destination.path.contains("/AppTranslocation/"),
              Bundle(url: destination)?.bundleIdentifier == "com.flux.menubar",
              manager.isWritableFile(atPath: parent.path) else { throw UpdateStageError.installLocation }
        let update = PreparedUpdate(token: UUID(), version: release.version)
        let token = update.token.uuidString
        let workspace = manager.temporaryDirectory.appendingPathComponent("flux-update-" + token)
        let directory = parent.appendingPathComponent(".Flux-update-" + token)
        let stage = Stage(update: update, workspace: workspace, mount: workspace.appendingPathComponent("volume"),
                          directory: directory, application: directory.appendingPathComponent("Flux.app"),
                          destination: destination, backup: parent.appendingPathComponent(".Flux-backup-" + token + ".app"))
        // Both parents are new, owned, mode0700 directories. Only this actor
        // knows their paths until the helper is ready.
        guard !manager.fileExists(atPath: workspace.path), !manager.fileExists(atPath: directory.path) else {
            throw UpdateStageError.stage
        }
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mayBeMounted = false
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: stage.mount, withIntermediateDirectories: false)
            let disk = workspace.appendingPathComponent("Flux.dmg")
            try await ReleaseDownload.fetch(release, to: disk)
            mayBeMounted = true
            try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["attach", disk.path,
                "-mountpoint", stage.mount.path, "-readonly", "-nobrowse", "-noautoopen", "-quiet"], seconds: 45)
            let candidate = stage.mount.appendingPathComponent("Flux.app")
            try await verifier.verify(candidate, expectedVersion: release.version)
            try await runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [candidate.path, stage.application.path], seconds: 120)
            try await runner.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", stage.application.path], seconds: 20)
            try await verifier.verify(stage.application, expectedVersion: release.version)
            try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", stage.mount.path, "-quiet"], seconds: 15)
            mayBeMounted = false
            try Task.checkCancellation()
            prepared = stage
            return update
        } catch {
            let runner = runner
            let needsDetach = mayBeMounted
            // Cancellation must not cancel the bounded cleanup command itself.
            await Task.detached(priority: .utility) {
                var detached = !needsDetach
                if needsDetach {
                    do {
                        try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                            arguments: ["detach", stage.mount.path, "-force", "-quiet"], seconds: 15)
                        detached = true
                    } catch {}
                }
                try? FileManager.default.removeItem(at: stage.directory)
                // Keep a possibly mounted workspace for recovery, never walk it.
                if detached { try? FileManager.default.removeItem(at: stage.workspace) }
            }.value
            throw error
        }
    }

    /// A non-writable install stays usable. Keep a verified image in a new
    /// private Downloads folder, and reuse it only while all bytes match.
    /// The caller opens it only after an explicit install action.
    public func prepareManual(_ release: ReleaseManifest) async throws -> URL {
        try Task.checkCancellation()
        guard !busy, prepared == nil else { throw UpdateStageError.busy }
        busy = true
        defer { busy = false }
        if let manualImage, let cached = try? manualImage.validatedFile(for: release) { return cached }
        try Task.checkCancellation()
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory.appendingPathComponent("flux-update-" + UUID().uuidString)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let mount = workspace.appendingPathComponent("volume")
        let disk = workspace.appendingPathComponent("Flux.dmg")
        var mounted = false
        var published: URL?
        do {
            try manager.createDirectory(at: mount, withIntermediateDirectories: false)
            try await ReleaseDownload.fetch(release, to: disk)
            mounted = true
            try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["attach", disk.path,
                "-mountpoint", mount.path, "-readonly", "-nobrowse", "-noautoopen", "-quiet"], seconds: 45)
            try await verifier.verify(mount.appendingPathComponent("Flux.app"), expectedVersion: release.version)
            try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mount.path, "-quiet"], seconds: 15)
            mounted = false
            try Task.checkCancellation()
            let downloads = try manager.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = downloads.appendingPathComponent("Flux-" + release.version.description + "-" + UUID().uuidString)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            published = directory
            let destination = directory.appendingPathComponent("Flux.dmg")
            try manager.moveItem(at: disk, to: destination)
            let cached = try UpdateImageCache(verifiedFile: destination, release: release)
            try Task.checkCancellation()
            try manager.removeItem(at: workspace)
            manualImage = cached
            return destination
        } catch {
            let runner = runner, needsDetach = mounted, directory = published
            await Task.detached(priority: .utility) {
                var detached = !needsDetach
                if needsDetach {
                    do {
                        try await runner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                            arguments: ["detach", mount.path, "-force", "-quiet"], seconds: 15)
                        detached = true
                    } catch {}
                }
                if let directory { try? FileManager.default.removeItem(at: directory) }
                if detached { try? FileManager.default.removeItem(at: workspace) }
            }.value
            throw error
        }
    }

    public func discard(_ update: PreparedUpdate) throws {
        guard !busy, let stage = prepared, stage.update.token == update.token else { throw UpdateStageError.notPrepared }
        try UpdateStageFiles.discard(directory: stage.directory, workspace: stage.workspace)
        prepared = nil
    }

    /// Returns only after the finite helper has written its readiness file.
    /// The app then stops its services, ends its session and quits.
    public func handOff(_ update: PreparedUpdate, parentPID: Int32) async throws {
        guard !busy, parentPID > 1, let stage = prepared, stage.update.token == update.token else {
            throw UpdateStageError.notPrepared
        }
        busy = true
        defer { busy = false }
        try await verifier.verify(stage.application, expectedVersion: update.version)
        try Task.checkCancellation()
        let helper = stage.workspace.appendingPathComponent("install.sh")
        let ready = stage.workspace.appendingPathComponent("ready")
        let log = stage.workspace.appendingPathComponent("install.log")
        let script = InstallHandoffScript.make(staged: stage.application, installURL: stage.destination,
            backup: stage.backup, workspace: stage.workspace, parentPID: parentPID)
        try Data(script.utf8).write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateStageError.helper
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", helper.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        do {
            while process.isRunning, !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            guard process.isRunning, FileManager.default.fileExists(atPath: ready.path) else { throw UpdateStageError.helper }
        } catch {
            if process.isRunning { process.terminate() }
            let stop = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < stop { try? await Task.sleep(for: .milliseconds(20)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        prepared = nil
    }
}

/// A stopped helper may already have removed either owned path. Retrying
/// cleanup must not strand the preparation token on an absent file.
enum UpdateStageFiles {
    static func discard(directory: URL, workspace: URL) throws {
        for path in [directory, workspace] {
            do { try FileManager.default.removeItem(at: path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
    }
}
