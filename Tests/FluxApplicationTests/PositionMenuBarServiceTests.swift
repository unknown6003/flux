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

@MainActor private final class HiderFixture: PerApplicationHidingOwner {
    var isAvailable = true
    var onResult: (@MainActor (Bool) -> Void)?
    var applied: [(policy: VisibilityPolicy, reveal: MenuBarReveal, always: Bool)] = []
    var stops = 0
    func apply(policy: VisibilityPolicy, reveal: MenuBarReveal, alwaysHiddenEnabled: Bool) {
        applied.append((policy, reveal, alwaysHiddenEnabled))
    }
    func stop() { stops += 1 }
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
    let hider = HiderFixture()
    let app = ApplicationID(rawValue: "org.fluxfixture.example")!
    var reads = 0
    var permissionRequests = 0
    var inventory: PositionMenuBarInventory
    var blockedRead: CheckedContinuation<Void, Never>?
    var blocksRead = false
    var previewCaptures = 0
    var previewCloses = 0
    var blocksPreview = false
    var blockedPreview: CheckedContinuation<Void, Never>?
    var previewImage: NSImage?
    var identityRequirement = Data([1])
    var identityMatch: Bool?
    var identityAvailable = true
    var identityAccepted = false
    var identityConfirmations = 0
    var blocksIdentityConfirmation = false
    var blockedIdentityConfirmation: CheckedContinuation<Bool, Never>?
    var blocksIdentityRead = false
    var blockedIdentityRead: CheckedContinuation<Void, Never>?
    var owner: PositionMenuBarService!
    var drags: [(CGPoint, CGPoint)] = []
    var onDrag: ((CGPoint, CGPoint) -> Void)?

    init(support: PositionMenuBarHidingSupport = .unverified) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        inventory = .init(applications: [.init(id: app, name: "Example", icon: nil,
            frames: [CGRect(x: 400, y: 0, width: 24, height: 24)])], accessibilityAllowed: true, complete: true)
        owner = PositionMenuBarService(defaults: defaults, domain: domain, preferences: preferences,
            hidingSupport: support, controls: controls,
            hider: support == .perApplication ? hider : nil, readInventory: { [unowned self] in
                guard !Task.isCancelled else { return self.inventory }
                self.reads += 1
                if self.blocksRead { await withCheckedContinuation { self.blockedRead = $0 } }
                return self.inventory
            }, permissionStatus: { .allowed }, requestPreviewPermission: { [unowned self] in
                self.permissionRequests += 1; return .allowed
            }, capturePreviews: { [unowned self] _ in
                self.previewCaptures += 1
                if self.blocksPreview { await withCheckedContinuation { self.blockedPreview = $0 } }
                guard let image = self.previewImage else { throw StatusPreviewError.unavailable }
                return [MenuBarItemID(application: self.app, index: 0): image]
            }, stopPreviews: { [unowned self] in self.previewCloses += 1 },
            screens: { [.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), menuBarHeight: 24)] },
            quartzFrame: { $0 }, sleep: { [delay] seconds in try await delay.sleep(seconds) }, observesSystem: false,
            readIdentity: { [unowned self] _, saved in
                let requirement = self.identityRequirement
                let matches = self.identityMatch ?? (saved == nil || saved == requirement)
                if self.blocksIdentityRead { await withCheckedContinuation { self.blockedIdentityRead = $0 } }
                guard self.identityAvailable else { return nil }
                return .init(requirement: requirement, matchesSaved: matches)
            }, confirmIdentity: { [unowned self] _ in
                self.identityConfirmations += 1
                if self.blocksIdentityConfirmation {
                    return await withCheckedContinuation { self.blockedIdentityConfirmation = $0 }
                }
                return self.identityAccepted
            }, tools: .init(drag: { [unowned self] from, to in
                self.drags.append((from, to))
                self.onDrag?(from, to)
            }, inputIsQuiet: { true }, previewAllowed: { false }, sleep: { _ in }, ownApplication: nil))
    }

    func settle() async { for _ in 0..<25 { await Task.yield() } }
    func close() async throws {
        delay.release()
        blockedRead?.resume(); blockedRead = nil
        blockedPreview?.resume(); blockedPreview = nil
        blockedIdentityConfirmation?.resume(returning: false); blockedIdentityConfirmation = nil
        blocksIdentityRead = false
        blockedIdentityRead?.resume(); blockedIdentityRead = nil
        try await owner.stop()
        defaults.removePersistentDomain(forName: domain)
    }
}

@Suite(.serialized) struct PositionMenuBarServiceTests {
    @Test @MainActor func perApplicationHidingAppliesSavedGroupsWithoutBackgroundReads() async throws {
        let fixture = try PositionServiceFixture(support: .perApplication)
        fixture.defaults.set(["hidden": [fixture.app.rawValue], "alwaysHidden": []], forKey: "flux.macOS27IconLayout")
        fixture.owner.configure()
        fixture.owner.start()
        await fixture.settle()
        #expect(fixture.reads == 0)
        #expect(fixture.owner.state.mode == .perApplication)
        #expect(fixture.controls.capability == .perApplication)
        let first = try #require(fixture.hider.applied.last)
        #expect(first.reveal == .collapsed)
        #expect(first.policy.group(for: fixture.app) == .hidden)
        fixture.owner.toggle()
        #expect(fixture.hider.applied.last?.reveal == .hidden)
        fixture.owner.toggle()
        #expect(fixture.hider.applied.last?.reveal == .collapsed)
        fixture.owner.setEditorVisible(true)
        #expect(fixture.hider.applied.last?.reveal == .all)
        try await fixture.close()
        #expect(fixture.hider.stops >= 1)
        #expect(fixture.hider.onResult == nil)
    }

    @Test @MainActor func perApplicationAssignmentReachesTheHiderAfterTheEditorCloses() async throws {
        let fixture = try PositionServiceFixture(support: .perApplication)
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.assign(fixture.app, to: .alwaysHidden)
        #expect(fixture.owner.state.rows.first?.result == .asked)
        fixture.owner.setEditorVisible(false)
        await fixture.settle()
        let last = try #require(fixture.hider.applied.last)
        #expect(last.reveal == .collapsed)
        #expect(last.policy.group(for: fixture.app) == .alwaysHidden)
        try await fixture.close()
    }

    @Test @MainActor func perApplicationRefusalAndMissingBridgeAreReported() async throws {
        let fixture = try PositionServiceFixture(support: .perApplication)
        fixture.owner.start()
        fixture.hider.onResult?(false)
        #expect(fixture.owner.state.mode == .failed(code: "hidingRefused"))
        fixture.hider.onResult?(true)
        #expect(fixture.owner.state.mode == .perApplication)
        fixture.hider.isAvailable = false
        fixture.owner.configure()
        #expect(fixture.owner.state.mode == .failed(code: "hidingUnavailable"))
        try await fixture.close()
    }

    @Test func perApplicationAllowListKeepsSystemItemsAndUnknownApps() {
        let hidden = ApplicationID(rawValue: "org.fluxfixture.hidden")!
        let list = PerApplicationHider.allowList(running: ["org.fluxfixture.hidden", "org.fluxfixture.other", "com.apple.controlcenter"],
                                                 concealed: [hidden])
        #expect(!list.contains("org.fluxfixture.hidden"))
        #expect(list.contains("org.fluxfixture.other"))
        #expect(list.contains("com.flux.menubar"))
        #expect(list.contains("com.apple.notificationcenterui"))
        #expect(list.contains("com.apple.TextInputMenuAgent"))
        #expect(list == list.sorted())
    }

    @Test func perApplicationAllowListDropsAHiddenSystemAgent() {
        let spotlight = ApplicationID(rawValue: "com.apple.Spotlight")!
        let list = PerApplicationHider.allowList(running: ["com.apple.Spotlight", "com.apple.controlcenter"],
                                                 concealed: [spotlight])
        #expect(!list.contains("com.apple.Spotlight"))
        #expect(list.contains("com.apple.controlcenter"))
        #expect(list.contains("com.apple.MenuBarAgent"))
    }

    @Test @MainActor func leavingTheEditorDuringReadCompletesAFreshBackgroundValidation() async throws {
        let fixture = try PositionServiceFixture(support: .byPosition)
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.blocksRead = true
        fixture.owner.refresh()
        await fixture.settle()
        let reads = fixture.reads
        fixture.blocksRead = false
        fixture.owner.setEditorVisible(false)
        await fixture.settle()
        #expect(fixture.reads == reads + 1)
        #expect(fixture.controls.capability == .byPosition)
        fixture.blockedRead?.resume(); fixture.blockedRead = nil
        await fixture.settle()
        #expect(fixture.controls.capability == .byPosition)
        try await fixture.close()
    }

    @Test @MainActor func replacementDuringAScanRequiresANewReadBeforeSavingOrHiding() async throws {
        let fixture = try PositionServiceFixture(support: .byPosition)
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        #expect(fixture.controls.capability == .byPosition)
        fixture.blocksIdentityRead = true
        fixture.owner.refresh()
        await fixture.settle()
        let reads = fixture.reads
        fixture.identityRequirement = Data([2])
        fixture.owner.refresh()
        fixture.owner.assign(fixture.app, to: .hidden)
        #expect(fixture.defaults.object(forKey: "flux.macOS27IconLayout") == nil)
        #expect(fixture.controls.capability == .unavailable)
        fixture.blocksIdentityRead = false
        fixture.blockedIdentityRead?.resume(); fixture.blockedIdentityRead = nil
        await fixture.settle()
        #expect(fixture.reads == reads + 1)
        #expect(fixture.owner.state.rows.first?.needsIdentityReview == true)
        #expect(fixture.controls.capability == .unavailable)
        #expect(fixture.defaults.object(forKey: "flux.macOS27IconLayout") == nil)
        try await fixture.close()
    }

    @Test @MainActor func changedIdentityNeedsConsentAndKeepsTheSavedVisibilityChoice() async throws {
        let fixture = try PositionServiceFixture(support: .byPosition)
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.assign(fixture.app, to: .hidden)
        let firstPins = try MenuBarIdentityPins(propertyList: fixture.defaults.object(forKey: "flux.menuBar.identities.v1"))
        #expect(firstPins.requirement(for: fixture.app) == Data([1]))
        fixture.identityRequirement = Data([2])
        fixture.owner.refresh()
        await fixture.settle()
        #expect(fixture.owner.state.rows.first?.needsIdentityReview == true)
        #expect(fixture.controls.capability == .unavailable)
        fixture.owner.assign(fixture.app, to: .shown)
        fixture.owner.reviewIdentity(fixture.app)
        await fixture.settle()
        #expect(fixture.identityConfirmations == 1)
        #expect(fixture.owner.state.rows.first?.needsIdentityReview == true)
        fixture.identityAccepted = true
        fixture.owner.reviewIdentity(fixture.app)
        await fixture.settle()
        let pins = try MenuBarIdentityPins(propertyList: fixture.defaults.object(forKey: "flux.menuBar.identities.v1"))
        let policy = try VisibilityPolicy(legacyPropertyList: fixture.defaults.object(forKey: "flux.macOS27IconLayout"))
        #expect(pins.requirement(for: fixture.app) == Data([2]))
        #expect(policy.group(for: fixture.app) == .hidden)
        #expect(fixture.owner.state.rows.first?.needsIdentityReview == false)
        try await fixture.close()
    }

    @Test @MainActor func aMatchingUpdateDoesNotReplaceThePinOrAskForReview() async throws {
        let fixture = try PositionServiceFixture()
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.identityRequirement = Data([3])
        fixture.identityMatch = true
        fixture.owner.refresh()
        await fixture.settle()
        let pins = try MenuBarIdentityPins(propertyList: fixture.defaults.object(forKey: "flux.menuBar.identities.v1"))
        #expect(pins.requirement(for: fixture.app) == Data([1]))
        #expect(fixture.owner.state.rows.first?.needsIdentityReview == false)
        #expect(fixture.identityConfirmations == 0)
        try await fixture.close()
    }

    @Test @MainActor func changingTheAppOrLeavingThePageCannotApproveAnOldReview() async throws {
        let fixture = try PositionServiceFixture()
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.identityRequirement = Data([2])
        fixture.owner.refresh()
        await fixture.settle()
        fixture.blocksIdentityConfirmation = true
        fixture.owner.reviewIdentity(fixture.app)
        await fixture.settle()
        fixture.identityRequirement = Data([3])
        fixture.blockedIdentityConfirmation?.resume(returning: true); fixture.blockedIdentityConfirmation = nil
        await fixture.settle()
        let first = try MenuBarIdentityPins(propertyList: fixture.defaults.object(forKey: "flux.menuBar.identities.v1"))
        #expect(first.requirement(for: fixture.app) == Data([1]))
        #expect(fixture.owner.state.mode == .failed(code: "identityChangedDuringReview"))
        fixture.owner.refresh()
        await fixture.settle()
        fixture.owner.reviewIdentity(fixture.app)
        await fixture.settle()
        fixture.owner.setEditorVisible(false)
        fixture.blockedIdentityConfirmation?.resume(returning: true); fixture.blockedIdentityConfirmation = nil
        await fixture.settle()
        let final = try MenuBarIdentityPins(propertyList: fixture.defaults.object(forKey: "flux.menuBar.identities.v1"))
        #expect(final.requirement(for: fixture.app) == Data([1]))
        try await fixture.close()
    }

    @Test @MainActor func invalidIdentityStorageAndMissingEvidenceLeavePinsAndGroupsUntouched() async throws {
        let fixture = try PositionServiceFixture(support: .byPosition)
        fixture.defaults.set(["version": 7, "requirements": [fixture.app.rawValue: Data([9])]],
                             forKey: "flux.menuBar.identities.v1")
        fixture.owner.start(); fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.assign(fixture.app, to: .hidden)
        #expect(fixture.controls.capability == .unavailable)
        #expect((fixture.defaults.dictionary(forKey: "flux.menuBar.identities.v1")?["version"] as? Int) == 7)
        #expect(fixture.defaults.object(forKey: "flux.macOS27IconLayout") == nil)
        try await fixture.close()
    }

    @Test @MainActor func aChoiceMadeDuringDoneWinsEvenWhenItRepeatsTheOriginalGroup() async throws {
        let fixture = try PositionServiceFixture()
        fixture.owner.start()
        fixture.owner.beginArrange()
        await fixture.settle()
        fixture.blocksRead = true
        fixture.owner.endArrange()
        await fixture.settle()
        // The geometry says Hidden, but the later explicit action says Shown.
        fixture.owner.assign(fixture.app, to: .shown)
        fixture.blockedRead?.resume(); fixture.blockedRead = nil
        await fixture.settle()
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: fixture.app) == .shown)
        #expect(fixture.owner.state.rows.first?.result == .notMovedYet)
        try await fixture.close()
    }

    @Test @MainActor func closingDoesNotWaitForAnUncancellableScreenshotOrPublishItsLateImage() async throws {
        let fixture = try PositionServiceFixture()
        fixture.blocksPreview = true
        fixture.previewImage = NSImage(size: .init(width: 24, height: 24))
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.showRealIcons()
        await fixture.settle()
        #expect(fixture.previewCaptures == 1)
        fixture.owner.setEditorVisible(false)
        try await fixture.owner.stop()
        #expect(fixture.previewCloses > 0)
        fixture.blockedPreview?.resume(); fixture.blockedPreview = nil
        await fixture.settle()
        #expect(!fixture.owner.state.showsRealIcons)
        #expect(fixture.owner.state.rows.allSatisfy { $0.preview == nil })
        try await fixture.close()
    }

    @Test @MainActor func refreshRevokesAnOldPreviewBeforeReadingNewGeometry() async throws {
        let fixture = try PositionServiceFixture()
        fixture.previewImage = NSImage(size: .init(width: 24, height: 24))
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        fixture.owner.showRealIcons()
        await fixture.settle()
        #expect(fixture.owner.state.showsRealIcons)
        #expect(fixture.owner.state.rows.first?.preview === fixture.previewImage)
        fixture.owner.refresh()
        #expect(!fixture.owner.state.showsRealIcons)
        #expect(fixture.owner.state.rows.allSatisfy { $0.preview == nil })
        try await fixture.close()
    }

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
        #expect(fixture.owner.state.mode == .failed(code: "previewUnavailable"))
        #expect(!fixture.owner.state.showsRealIcons)
        #expect(fixture.owner.state.rows.allSatisfy { $0.preview == nil })
        fixture.owner.reviewIdentity(fixture.app)
        #expect(fixture.identityConfirmations == 0)
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

    @MainActor private func twoItemFixture(support: PositionMenuBarHidingSupport) async throws -> (PositionServiceFixture, ApplicationID) {
        let fixture = try PositionServiceFixture(support: support)
        let second = try #require(ApplicationID(rawValue: "org.fluxfixture.second"))
        fixture.inventory = .init(applications: [
            .init(id: fixture.app, name: "Example", icon: nil, frames: [CGRect(x: 400, y: 0, width: 24, height: 24)]),
            .init(id: second, name: "Second", icon: nil, frames: [CGRect(x: 450, y: 0, width: 24, height: 24)]),
        ], accessibilityAllowed: true, complete: true)
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        return (fixture, second)
    }

    @Test @MainActor func chevronMenuOffersOnlySettingsAndQuit() async throws {
        let fixture = try PositionServiceFixture(support: .perApplication)
        fixture.owner.start()
        #expect(fixture.controls.contextMenu?.items.map(\.title) == ["Settings…", "Quit Flux"])
        try await fixture.close()
    }

    @Test @MainActor func editorTilesFollowTheRealOrderAndSavedGroups() async throws {
        let (fixture, second) = try await twoItemFixture(support: .perApplication)
        #expect(fixture.owner.state.tiles.map(\.id.application) == [fixture.app, second])
        #expect(fixture.owner.state.tiles.map(\.name) == ["Example", "Second"])
        #expect(fixture.owner.state.tiles.allSatisfy { $0.group == .shown })
        #expect(fixture.owner.state.layoutAccessible)
        try await fixture.close()
    }

    @Test @MainActor func perAppMoveIntoAnEmptyStripSavesTheGroupWithoutDragging() async throws {
        let (fixture, _) = try await twoItemFixture(support: .perApplication)
        let item = MenuBarItemID(application: fixture.app, index: 0)
        fixture.owner.moveItem(.init(item: item, group: .hidden, left: nil, right: nil))
        await fixture.settle(); await fixture.settle()
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: fixture.app) == .hidden)
        #expect(fixture.drags.isEmpty)
        #expect(fixture.owner.state.moveStatus == .moved(name: "Example"))
        #expect(fixture.owner.state.tiles.first { $0.id == item }?.group == .hidden)
        // The editor keeps every item visible while it is open.
        #expect(fixture.hider.applied.last?.reveal == .all)
        try await fixture.close()
    }

    @Test @MainActor func reorderDragsAndVerifiesAgainstAFreshRead() async throws {
        let (fixture, second) = try await twoItemFixture(support: .perApplication)
        fixture.onDrag = { _, _ in
            fixture.inventory = .init(applications: [
                .init(id: fixture.app, name: "Example", icon: nil, frames: [CGRect(x: 450, y: 0, width: 24, height: 24)]),
                .init(id: second, name: "Second", icon: nil, frames: [CGRect(x: 400, y: 0, width: 24, height: 24)]),
            ], accessibilityAllowed: true, complete: true)
        }
        fixture.owner.moveItem(.init(item: .init(application: second, index: 0), group: .shown,
                                     left: nil, right: .init(application: fixture.app, index: 0)))
        await fixture.settle(); await fixture.settle()
        #expect(fixture.drags.count == 1)
        #expect(fixture.drags.first?.0 == CGPoint(x: 462, y: 12))
        #expect(fixture.drags.first?.1 == CGPoint(x: 408, y: 12))
        #expect(fixture.owner.state.moveStatus == .moved(name: "Second"))
        #expect(fixture.owner.state.tiles.map(\.id.application) == [second, fixture.app])
        try await fixture.close()
    }

    @Test @MainActor func aRefusedReorderReportsOneClearFailure() async throws {
        let (fixture, second) = try await twoItemFixture(support: .perApplication)
        fixture.owner.moveItem(.init(item: .init(application: second, index: 0), group: .shown,
                                     left: nil, right: .init(application: fixture.app, index: 0)))
        // A second request while the first runs is ignored.
        fixture.owner.moveItem(.init(item: .init(application: fixture.app, index: 0), group: .hidden, left: nil, right: nil))
        await fixture.settle(); await fixture.settle(); await fixture.settle()
        #expect(fixture.drags.count == MenuBarMoveEngine.attempts)
        #expect(fixture.owner.state.moveStatus == .failed(name: "Second", .notAccepted))
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: fixture.app) == .shown)
        try await fixture.close()
    }

    @Test @MainActor func byPositionGroupChangeDragsAcrossTheBoundaryAndSavesTheResult() async throws {
        let (fixture, second) = try await twoItemFixture(support: .byPosition)
        #expect(fixture.owner.state.mode == .byPosition)
        // Boundaries: Always Hidden at 300, Hidden at 600. Both items are left of 600, so Hidden.
        #expect(fixture.owner.state.tiles.allSatisfy { $0.group == .hidden })
        fixture.onDrag = { _, _ in
            fixture.inventory = .init(applications: [
                .init(id: fixture.app, name: "Example", icon: nil, frames: [CGRect(x: 400, y: 0, width: 24, height: 24)]),
                .init(id: second, name: "Second", icon: nil, frames: [CGRect(x: 700, y: 0, width: 24, height: 24)]),
            ], accessibilityAllowed: true, complete: true)
        }
        fixture.owner.moveItem(.init(item: .init(application: second, index: 0), group: .shown, left: nil, right: nil))
        await fixture.settle(); await fixture.settle(); await fixture.settle()
        #expect(fixture.drags.first?.1.x == 624)
        #expect(fixture.owner.state.moveStatus == .moved(name: "Second"))
        let saved = try VisibilityPolicy(legacyPropertyList: fixture.defaults.persistentDomain(forName: fixture.domain)?["flux.macOS27IconLayout"])
        #expect(saved.group(for: second) == .shown)
        #expect(saved.group(for: fixture.app) == .hidden)
        try await fixture.close()
    }

    @Test @MainActor func lostAccessibilityShowsInTheEditorState() async throws {
        let fixture = try PositionServiceFixture(support: .perApplication)
        fixture.inventory = .init(applications: [], accessibilityAllowed: false, complete: false)
        fixture.owner.start()
        fixture.owner.setEditorVisible(true)
        await fixture.settle()
        #expect(!fixture.owner.state.layoutAccessible)
        #expect(fixture.owner.state.tiles.isEmpty)
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
