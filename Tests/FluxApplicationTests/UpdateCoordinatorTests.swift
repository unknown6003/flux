import Foundation
import Testing
import FluxCore
import FluxPlatform
import FluxUI
@testable import FluxApplication

private actor PendingUpdateBackend: UpdateBackend {
    private(set) var requests = 0
    private(set) var preparations = 0
    private var pending: CheckedContinuation<ReleaseManifest, any Error>?
    func latest() async throws -> ReleaseManifest {
        requests += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func answer(_ release: ReleaseManifest) { pending?.resume(returning: release); pending = nil }
    func prepare(_ release: ReleaseManifest, replacing: URL) async throws -> PreparedUpdate {
        preparations += 1
        throw UpdateStageError.installLocation
    }
    func handOff(_ update: PreparedUpdate, parentPID: Int32) throws { throw UpdateStageError.notPrepared }
    func discard(_ update: PreparedUpdate) throws { throw UpdateStageError.notPrepared }
}

struct UpdateCoordinatorTests {
    private func release() throws -> ReleaseManifest {
        try ReleaseManifest(data: Data(#"{"tag_name":"v0.22.0","draft":false,"prerelease":false,"assets":[{"name":"Flux.dmg","state":"uploaded","size":8,"browser_download_url":"https://github.com/unknown6003/flux/releases/download/v0.22.0/Flux.dmg"}]}"#.utf8))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func anAutomaticLocationFailureWaitsForAnExplicitManualInstallAction() async throws {
        let backend = PendingUpdateBackend()
        var pages = 0
        let owner = UpdateCoordinator(version: "0.21.35", installURL: URL(fileURLWithPath: "/fixture/Flux.app"),
            backend: backend, changed: {}, readyToQuit: { Issue.record("Unexpected quit") },
            manualInstall: { _ in pages += 1 })
        defer { owner.stop() }
        owner.start(automatic: true)
        owner.check(userInitiated: false)
        let clock = ContinuousClock()
        let request = clock.now.advanced(by: .seconds(2))
        while await backend.requests == 0, clock.now < request { try await Task.sleep(for: .milliseconds(10)) }
        await backend.answer(try release())
        let automatic = clock.now.advanced(by: .seconds(2))
        while await backend.preparations == 0, clock.now < automatic { try await Task.sleep(for: .milliseconds(10)) }
        while owner.status == .installing, clock.now < automatic { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await backend.preparations == 1)
        #expect(pages == 0)
        owner.install()
        let manual = clock.now.advanced(by: .seconds(2))
        while pages == 0, clock.now < manual { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pages == 1)
        #expect(await backend.preparations == 2)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func aManualCheckAdoptsAnAutomaticRequestWithoutInstallingOrDownloadingTwice() async throws {
        let backend = PendingUpdateBackend()
        var manualPages: [URL] = []
        let owner = UpdateCoordinator(version: "0.21.35", installURL: URL(fileURLWithPath: "/fixture/Flux.app"),
            backend: backend, changed: {}, readyToQuit: { Issue.record("Unexpected quit") },
            manualInstall: { manualPages.append($0) })
        defer { owner.stop() }
        owner.start(automatic: true)
        owner.check(userInitiated: false)
        owner.check(userInitiated: true)
        let clock = ContinuousClock()
        let started = clock.now.advanced(by: .seconds(2))
        while await backend.requests == 0, clock.now < started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.status == .checking)
        await backend.answer(try release())
        let completed = clock.now.advanced(by: .seconds(2))
        while owner.status == .checking, clock.now < completed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner.status == .available(version: "0.22.0"))
        #expect(await backend.requests == 1)
        #expect(await backend.preparations == 0)
        owner.install()
        owner.install()
        let install = clock.now.advanced(by: .seconds(2))
        while manualPages.isEmpty, clock.now < install { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await backend.preparations == 1)
        #expect(manualPages == [try release().pageURL])
        #expect(owner.status == .available(version: "0.22.0"))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func aStoppedUpdaterDropsLateResultsWithoutOpeningPagesOrQuitting() async throws {
        let backend = PendingUpdateBackend()
        var changes = 0
        let owner = UpdateCoordinator(version: "0.21.35", installURL: URL(fileURLWithPath: "/fixture/Flux.app"),
            backend: backend, changed: { changes += 1 }, readyToQuit: { Issue.record("Unexpected quit") },
            manualInstall: { _ in Issue.record("Unexpected page") })
        owner.start(automatic: false)
        owner.check()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await backend.requests == 0, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        owner.stop()
        let before = changes
        await backend.answer(try release())
        try await Task.sleep(for: .milliseconds(20))
        #expect(changes == before)
        #expect(await backend.preparations == 0)
    }
}
