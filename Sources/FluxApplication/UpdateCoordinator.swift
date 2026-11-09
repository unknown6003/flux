import Foundation
import FluxCore
import FluxPlatform
import FluxUI

protocol UpdateBackend: Sendable {
    func latest() async throws -> ReleaseManifest
    func prepare(_ release: ReleaseManifest, replacing: URL) async throws -> PreparedUpdate
    func prepareManual(_ release: ReleaseManifest) async throws -> URL
    func handOff(_ update: PreparedUpdate, parentPID: Int32) async throws
    func discard(_ update: PreparedUpdate) async throws
}

private actor NativeUpdates: UpdateBackend {
    private var client: ReleaseClient?
    private var installer: UpdateStager?
    func latest() async throws -> ReleaseManifest {
        let client = client ?? ReleaseClient()
        self.client = client
        return try await client.latest()
    }
    func prepare(_ release: ReleaseManifest, replacing url: URL) async throws -> PreparedUpdate {
        let installer = installer ?? UpdateStager()
        self.installer = installer
        return try await installer.prepare(release, replacing: url)
    }
    func prepareManual(_ release: ReleaseManifest) async throws -> URL {
        let installer = installer ?? UpdateStager()
        self.installer = installer
        return try await installer.prepareManual(release)
    }
    func handOff(_ update: PreparedUpdate, parentPID: Int32) async throws {
        guard let installer else { throw UpdateStageError.notPrepared }
        try await installer.handOff(update, parentPID: parentPID)
    }
    func discard(_ update: PreparedUpdate) async throws {
        guard let installer else { throw UpdateStageError.notPrepared }
        try await installer.discard(update)
    }
}

/// The app owns this coordinator from ready until shutdown. No session or
/// timer is created while automatic checks are off and no check was requested.
@MainActor public final class UpdateCoordinator {
    public private(set) var status: UpdateStatus = .idle
    private let current: ReleaseVersion?
    private let installURL: URL
    private let backend: any UpdateBackend
    private let changed: @MainActor () -> Void
    private let readyToQuit: @MainActor () -> Void
    private let manualInstall: @MainActor (URL) -> Void
    private var work: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var release: ReleaseManifest?
    private var active = false
    private var automatic = false
    private var checking = false
    private var userRequested = false

    public convenience init(version: String, installURL: URL, changed: @escaping @MainActor () -> Void,
                            readyToQuit: @escaping @MainActor () -> Void,
                            manualInstall: @escaping @MainActor (URL) -> Void) {
        self.init(version: version, installURL: installURL, backend: NativeUpdates(),
                  changed: changed, readyToQuit: readyToQuit, manualInstall: manualInstall)
    }

    init(version: String, installURL: URL, backend: any UpdateBackend,
         changed: @escaping @MainActor () -> Void, readyToQuit: @escaping @MainActor () -> Void,
         manualInstall: @escaping @MainActor (URL) -> Void) {
        current = ReleaseVersion(version); self.installURL = installURL; self.backend = backend
        self.changed = changed; self.readyToQuit = readyToQuit; self.manualInstall = manualInstall
    }

    deinit { work?.cancel(); schedule?.cancel() }

    public func start(automatic: Bool) {
        active = true
        setAutomatic(automatic)
    }

    public func setAutomatic(_ enabled: Bool) {
        guard active, automatic != enabled || (enabled && schedule == nil) else { return }
        automatic = enabled
        schedule?.cancel(); schedule = nil
        guard enabled else { return }
        schedule = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            while !Task.isCancelled {
                guard self?.active == true, self?.automatic == true else { return }
                self?.check(userInitiated: false)
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
            }
        }
    }

    public func stop() {
        active = false
        schedule?.cancel(); schedule = nil
        work?.cancel(); work = nil
    }

    public func clearStaleOutcome() {
        guard work == nil else { return }
        switch status {
        case .upToDate, .failed: set(.idle)
        default: break
        }
    }

    public func check(userInitiated: Bool = true) {
        guard active else { return }
        if work != nil {
            if checking, userInitiated { userRequested = true; set(.checking) }
            return
        }
        guard let current else { set(.failed(code: "update.version")); return }
        checking = true; userRequested = userInitiated
        if userInitiated { set(.checking) }
        let backend = backend
        work = Task { @MainActor [weak self] in
            let answer: Result<ReleaseManifest, any Error>
            do { answer = .success(try await backend.latest()) } catch { answer = .failure(error) }
            guard let self, self.active, !Task.isCancelled else { return }
            self.work = nil; self.checking = false
            let manual = self.userRequested
            self.userRequested = false
            switch answer {
            case .success(let release) where release.version > current:
                self.release = release
                self.set(.available(version: release.version.description))
                if !manual, self.automatic { self.install(userInitiated: false) }
            case .success:
                self.release = nil
                if manual || self.status != .idle { self.set(.upToDate) }
            case .failure:
                if manual { self.set(.failed(code: "update.check")) }
            }
        }
    }

    public func install(userInitiated: Bool = true) {
        guard active, work == nil, let release else { return }
        set(.installing)
        let backend = backend, installURL = installURL
        work = Task { @MainActor [weak self] in
            var prepared: PreparedUpdate?
            do {
                let update = try await backend.prepare(release, replacing: installURL)
                prepared = update
                try Task.checkCancellation()
                try await backend.handOff(update, parentPID: getpid())
                prepared = nil
                guard let self, self.active else { return }
                self.work = nil
                self.readyToQuit()
            } catch {
                if let prepared { try? await backend.discard(prepared) }
                guard let self, self.active, !Task.isCancelled else { return }
                if let error = error as? UpdateStageError, case .installLocation = error {
                    do {
                        let disk = try await backend.prepareManual(release)
                        guard self.active, !Task.isCancelled else { return }
                        self.work = nil
                        self.set(.available(version: release.version.description))
                        if userInitiated { self.manualInstall(disk) }
                    } catch {
                        guard self.active, !Task.isCancelled else { return }
                        self.work = nil
                        self.set(.failed(code: "update.download"))
                    }
                } else {
                    self.work = nil
                    self.set(.failed(code: "update.install"))
                }
            }
        }
    }

    private func set(_ status: UpdateStatus) {
        guard self.status != status else { return }
        self.status = status
        changed()
    }
}
