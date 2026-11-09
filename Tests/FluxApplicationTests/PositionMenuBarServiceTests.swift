import AppKit
import Testing
import FluxCore
import FluxPlatform
import FluxUI
@testable import FluxApplication

@MainActor private final class PositionControlsFixture: PositionMenuBarControlOwner {
    var onToggle: (@MainActor (Bool) -> Void)?
    var onFinishArrange: (@MainActor () -> Void)?
    var contextMenu: NSMenu?
    var hiddenBoundary: CGRect? = CGRect(x: 600, y: 0, width: 40, height: 24)
    var alwaysHiddenBoundary: CGRect? = CGRect(x: 300, y: 0, width: 40, height: 24)
    var capability: MenuBarCapability = .unavailable
    var reveal: MenuBarReveal = .all
    var started = false
    var arranging = false
    var stopSawUnavailable = false
    func start() { started = true }
    func stop() { stopSawUnavailable = capability == .unavailable && reveal == .all; started = false }
    func configure(capability: MenuBarCapability, reveal: MenuBarReveal, alwaysHiddenEnabled: Bool, style: MenuBarIcon) {
        self.capability = capability; self.reveal = reveal
    }
    func setArranging(_ arranging: Bool) { self.arranging = arranging }
}

@MainActor private final class PositionDelayFixture {
    var requested: [TimeInterval] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        requested.append(seconds)
        await withCheckedContinuation { pending.append($0) }
        try Task.checkCancellation()
    }
    func release() {
        let continuations = pending; pending = []
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor private final class PositionServiceFixture {
    let domain = "org.fluxfixture.position.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: PreferenceStore
    let controls = PositionControlsFixture()
    let delay = PositionDelayFixture()
    let app = ApplicationID(rawValue: "org.fluxfixture.example")!
    var reads = 0
    var permissionRequests = 0
    var inventory: PositionMenuBarInventory
    var blockedRead: CheckedContinuation<Void, Never>?
    var blocksRead = false
    var owner: PositionMenuBarService!

    init(support: PositionMenuBarHidingSupport = .unverified) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        inventory = .init(applications: [.init(id: app, name: "Example", icon: nil,
            frames: [CGRect(x: 400, y: 0, width: 24, height: 24)])], accessibilityAllowed: true, complete: true)
        owner = PositionMenuBarService(defaults: defaults, domain: domain, preferences: preferences,
            hidingSupport: support, controls: controls, readInventory: { [unowned self] in
                guard !Task.isCancelled else { return self.inventory }
                self.reads += 1
                if self.blocksRead { await withCheckedContinuation { self.blockedRead = $0 } }
                return self.inventory
            }, permissionStatus: { .allowed }, requestPreviewPermission: { [unowned self] in
                self.permissionRequests += 1; return .allowed
            }, screens: { [.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), menuBarHeight: 24)] },
            quartzFrame: { $0 }, sleep: { [delay] seconds in try await delay.sleep(seconds) }, observesSystem: false)
    }

    func settle() async { for _ in 0..<25 { await Task.yield() } }
    func close() async throws {
        delay.release()
        blockedRead?.resume(); blockedRead = nil
        try await owner.stop()
        defaults.removePersistentDomain(forName: domain)
    }
}

@Suite(.serialized) struct PositionMenuBarServiceTests {
    @Test @MainActor func unverifiedHasRealControlsAndNoIdleInventoryOrSpacer() async throws {
        let fixture = try PositionServiceFixture()
        fixture.owner.start()
        await fixture.settle()
        #expect(fixture.controls.started)
        #expect(fixture.controls.contextMenu?.items.contains(where: { $0.title == "Settings…" }) == true)
        #expect(fixture.controls.capability == .unavailable)
        #expect(fixture.owner.state.mode == .paused)
        #expect(fixture.reads == 0)
        #expect(fixture.permissionRequests == 0)
        fixture.owner.showAll()
        #expect(fixture.controls.capability == .unavailable)
        try await fixture.close()
        #expect(fixture.controls.stopSawUnavailable)
    }

    @Test @MainActor func assignmentMergesTheExplicitSuiteAndDoesNotMoveAnything() async throws {
        let fixture = try PositionServiceFixture()
        fixture.defaults.set(["hidden": [String](), "alwaysHidden": [String](), "future": ["version": 7]],
                             forKey: "flux.macOS27IconLayout")
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.assign(fixture.app, to: .alwaysHidden)
        let saved = try #require(fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"] as? [String: Any])
        #expect((saved["future"] as? [String: Int])?["version"] == 7)
        #expect(saved["hidden"] as? [String] == [fixture.app.rawValue])
        #expect(saved["alwaysHidden"] as? [String] == [fixture.app.rawValue])
        #expect(fixture.owner.state.rows.first?.result == .notMovedYet)
        #expect(fixture.controls.reveal == .all)
        #expect(fixture.controls.capability == .unavailable)
        #expect(!fixture.controls.arranging)
        try await fixture.close()
    }

    @Test @MainActor func editorCancelsRehideAndOnlyExplicitRevealRestartsIt() async throws {
        let fixture = try PositionServiceFixture(support: .byPosition)
        try fixture.preferences.set(100, for: Preferences.autoRehideDelay)
        fixture.owner.start()
        fixture.owner.showAll()
        await fixture.settle()
        #expect(fixture.delay.requested == [30])
        fixture.owner.setEditorVisible(true)
        fixture.delay.release()
        await fixture.settle()
        #expect(fixture.controls.reveal == .all)
        fixture.owner.setEditorVisible(false)
        await fixture.settle()
        #expect(fixture.delay.requested == [30])
        fixture.owner.toggle()
        #expect(fixture.controls.reveal == .collapsed)
        fixture.owner.toggle()
        await fixture.settle()
        #expect(fixture.delay.requested == [30, 30])
        fixture.delay.release()
        await fixture.settle()
        #expect(fixture.controls.reveal == .collapsed)
        try await fixture.close()
    }

    @Test @MainActor func closingEditorRejectsAnInflightScanAndReleasesPreviewDemand() async throws {
        let fixture = try PositionServiceFixture()
        fixture.blocksRead = true
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        #expect(fixture.reads == 1)
        fixture.owner.refresh()
        fixture.owner.refresh()
        #expect(fixture.reads == 1)
        fixture.owner.showRealIcons()
        fixture.owner.setEditorVisible(false)
        fixture.blockedRead?.resume(); fixture.blockedRead = nil
        await fixture.settle()
        #expect(fixture.owner.state.rows.isEmpty)
        #expect(!fixture.owner.state.isRefreshing)
        #expect(fixture.permissionRequests == 0)
        fixture.owner.showRealIcons()
        #expect(fixture.permissionRequests == 0)
        try await fixture.close()
    }

    @Test @MainActor func geometrySaveNeedsFreshCompleteReadAndPreservesUnknownAssignments() async throws {
        let fixture = try PositionServiceFixture()
        let unknown = ApplicationID(rawValue: "org.fluxfixture.unknown")!
        fixture.defaults.set(["hidden": [fixture.app.rawValue, unknown.rawValue],
                              "alwaysHidden": [unknown.rawValue], "future": true], forKey: "flux.macOS27IconLayout")
        fixture.owner.start()
        fixture.owner.beginArrange()
        await fixture.settle()
        fixture.inventory = .init(applications: [
            .init(id: fixture.app, name: "Example", icon: nil, frames: [CGRect(x: 700, y: 0, width: 24, height: 24)]),
            .init(id: unknown, name: "Unknown", icon: nil, frames: [nil])
        ], accessibilityAllowed: true, complete: true)
        fixture.owner.endArrange()
        await fixture.settle()
        #expect(fixture.reads == 2)
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: fixture.app) == .shown)
        #expect(saved.group(for: unknown) == .alwaysHidden)
        #expect(fixture.owner.state.rows.allSatisfy { $0.result != .savedInMacOS })
        #expect(!fixture.owner.state.isArranging)
        #expect(fixture.controls.reveal == .collapsed)
        try await fixture.close()
    }

    @Test @MainActor func explicitUnsupportedActionsFailAndDoNotCaptureOrApprove() async throws {
        let fixture = try PositionServiceFixture()
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.showRealIcons()
        await fixture.settle()
        #expect(fixture.permissionRequests == 1)
        #expect(fixture.owner.state.mode == .failed(code: "previewEligibilityUnavailable"))
        #expect(!fixture.owner.state.showsRealIcons)
        #expect(fixture.owner.state.rows.allSatisfy { $0.preview == nil })
        fixture.owner.reviewIdentity(fixture.app)
        #expect(fixture.owner.state.rows.first?.result == .failed(code: "identityReviewUnavailable"))
        fixture.owner.setCompactSpacing(true)
        #expect(fixture.owner.state.options.compactSpacing == nil)
        #expect(fixture.owner.state.mode == .failed(code: "compactSpacingUnavailable"))
        try await fixture.close()
    }

    @Test @MainActor func movingBoundaryDuringReadPreservesTheSavedGroup() async throws {
        let fixture = try PositionServiceFixture()
        fixture.defaults.set(["hidden": [String](), "alwaysHidden": [String]()], forKey: "flux.macOS27IconLayout")
        fixture.owner.start()
        fixture.owner.beginArrange()
        await fixture.settle()
        fixture.blocksRead = true
        fixture.owner.endArrange()
        await fixture.settle()
        fixture.controls.hiddenBoundary = CGRect(x: 650, y: 0, width: 40, height: 24)
        fixture.blockedRead?.resume(); fixture.blockedRead = nil
        await fixture.settle()
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: fixture.app) == .shown)
        #expect(!fixture.owner.state.isArranging)
        try await fixture.close()
    }

    @Test @MainActor func overlappingSplitAndOffscreenGeometryNeverChangePolicy() throws {
        let app = try #require(ApplicationID(rawValue: "org.fluxfixture.geometry"))
        let screen = PositionMenuBarScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), menuBarHeight: 24)
        let hidden = CGRect(x: 600, y: 0, width: 40, height: 24)
        let always = CGRect(x: 300, y: 0, width: 40, height: 24)
        let cases: [[CGRect?]] = [
            [CGRect(x: 400, y: 0, width: -24, height: 24)],
            [CGRect(x: 400, y: 0, width: 24, height: -24)],
            [CGRect(x: 590, y: 0, width: 24, height: 24)],
            [CGRect(x: 200, y: 0, width: 24, height: 24), CGRect(x: 700, y: 0, width: 24, height: 24)],
            [CGRect(x: -50, y: 0, width: 24, height: 24)],
            [CGRect(x: 400, y: 100, width: 24, height: 24)],
            [CGRect(x: 400, y: 0, width: 24, height: 24), CGRect(x: 410, y: 0, width: 24, height: 24)],
            [nil]
        ]
        for frames in cases {
            let result = PositionMenuBarGeometry.assignments(applications: [.init(id: app, name: "App", icon: nil, frames: frames)],
                hidden: hidden, always: always, screens: [screen], alwaysEnabled: true)
            #expect(result.isEmpty)
        }
    }
}
