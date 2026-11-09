import AppKit
import Foundation
import Testing
import FluxCore
import FluxUI
@testable import FluxApplication

@MainActor private final class SettingsFixtureEffects: SettingsEffects {
    var changes: [SettingsChange] = []
    var failures: [SettingsFailure] = []
    var visits: [String] = []
    func settingsWillShow(_ page: SettingsPage) { visits.append("show." + page.rawValue) }
    func settingsWillHide(_ page: SettingsPage) { visits.append("hide." + page.rawValue) }
    func loginStatus() -> LoginStatus { .disabled }
    func shortcutConflict(_ role: ShortcutRole) -> ShortcutConflict { .clear }
    func updateStatus() -> UpdateStatus { .idle }
    func permissionRows() -> [PermissionRow] { [] }
    func notchAccess(_ kind: NotchAccessKind) -> NotchAccessStatus { .notAsked }
    func lockScreenCapability() -> LockScreenCapability { .unavailable }
    func lockScreenFailureCode() -> String? { nil }
    func crashNotice() -> CrashNotice { .none }
    func menuBarState() -> MenuBarPageState { .init(mode: .paused) }
    func apply(_ change: SettingsChange) { changes.append(change) }
    func report(_ failure: SettingsFailure) { failures.append(failure) }
    private func unexpected() { Issue.record("An unrelated platform effect ran from a preference action") }
    func setLoginItem(_ enabled: Bool) throws -> LoginStatus { unexpected(); return .disabled }
    func openLoginItemsSettings() { unexpected() }
    func replaceShortcut(_ role: ShortcutRole, with shortcut: Shortcut) -> Bool { unexpected(); return false }
    func checkForUpdates() { unexpected() }
    func installUpdate() { unexpected() }
    func openPermissionSettings(_ kind: PermissionKind) { unexpected() }
    func requestNotchAccess(_ kind: NotchAccessKind) { unexpected() }
    func openNotchAccessSettings(_ kind: NotchAccessKind) { unexpected() }
    func setClipboardPersistence(_ enabled: Bool) async throws { unexpected() }
    func clearClipboardHistory() async throws { unexpected() }
    func openLockScreenSettings() { unexpected() }
    func checkLockScreenAgain() { unexpected() }
    func copyDiagnosticReport() -> Bool { unexpected(); return false }
    func dismissCrashNotice() { unexpected() }
    func openMediaRemoteAdapterLicense() { unexpected() }
    func openSourceRepository() { unexpected() }
    func assign(_ application: ApplicationID, to group: MenuBarGroup) { unexpected() }
    func beginArrange() { unexpected() }
    func endArrange() { unexpected() }
    func showRealIcons() { unexpected() }
    func refreshMenuBar() { unexpected() }
    func openAccessibilitySettings() { unexpected() }
    func checkAccessibility() { unexpected() }
    func reviewIdentity(_ application: ApplicationID) { unexpected() }
    func setCompactSpacing(_ enabled: Bool) { unexpected() }
}

@Suite(.serialized)
struct SettingsCoordinatorTests {
    @MainActor fileprivate static func find(_ id: String) -> NSView? {
        @MainActor func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap(walk).first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(walk) }.first
    }

    @Test @MainActor func realSettingsControlsSaveBeforeApplyingAndRefreshWithoutEffects() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        enum UnexpectedAnalytics: Error { case constructed }
        let usage = UsageCollection(defaults: defaults) { _ in
            Issue.record("Analytics was constructed by opening Settings")
            throw UnexpectedAnalytics.constructed
        }
        let effects = SettingsFixtureEffects()
        let settings = SettingsCoordinator(preferences: preferences, usage: usage,
                                           version: .init(), effects: effects)
        defer { settings.close() }
        settings.show(.general)
        #expect(effects.visits == ["show.general"])
        #expect(effects.changes.isEmpty)
        let hotkeys = try #require(Self.find("general.hotkeys") as? NSSwitch)
        hotkeys.state = .off
        _ = hotkeys.sendAction(hotkeys.action, to: hotkeys.target)
        #expect(!preferences.value(for: Preferences.enableHotkey))
        #expect(effects.changes.count == 1)
        if case .some(.hotkeysEnabled(false)) = effects.changes.first {} else { Issue.record("Wrong runtime effect") }
        settings.refresh()
        #expect(effects.changes.count == 1)

        settings.show(.notch)
        #expect(effects.visits == ["show.general", "hide.general", "show.notch"])
        let clipboard = try #require(Self.find("notch.widget.clipboard") as? NSSwitch)
        #expect(clipboard.state == .off)
        clipboard.state = .on
        _ = clipboard.sendAction(clipboard.action, to: clipboard.target)
        #expect(preferences.value(for: Preferences.clipboardEnabled))
        #expect(!preferences.value(for: Preferences.clipboardPersistenceEnabled))
        #expect(effects.changes.count == 2)
        if case .some(.features(let config)) = effects.changes.last {
            #expect(config.enabledWidgets.contains(.clipboard))
        } else { Issue.record("Clipboard did not update service demand") }
        #expect(effects.failures.isEmpty)
        #expect(!usage.enabled)
        #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)
        settings.close()
        #expect(effects.visits.last == "hide.notch")
    }

    @Test func widgetOrderMovesKnownNeighborsWithoutDiscardingFutureIDs() {
        var order = WidgetOrder(saved: ["future.first", "mirror", "future.middle", "shelf", "mirror", "calendar"])
        let moved = order.move(.shelf, up: true)
        #expect(moved)
        #expect(order.saved.prefix(4) == ["future.first", "shelf", "future.middle", "mirror"])
        #expect(order.widgets == [.shelf, .mirror, .calendar, .nowPlaying, .clipboard])
        let movedPastFirst = order.move(.shelf, up: true)
        #expect(!movedPastFirst)
    }
}

private actor RatingFixtureTransport: UsageTransport {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<UsageResponse, Never>?
    private var requests: [UsageRequest] = []
    init() { (started, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func send(_ request: UsageRequest) async throws -> UsageResponse {
        requests.append(request)
        return await withCheckedContinuation { pending = $0; continuation.yield(()) }
    }
    func release(accepted: Bool = true) {
        pending?.resume(returning: UsageResponse(status: 200,
            body: Data((accepted ? #"{"status":1}"# : #"{"status":0}"#).utf8)))
        pending = nil
    }
    func snapshot() -> [UsageRequest] { requests }
}

@MainActor private final class RatingFixture {
    let domain = "org.fluxfixture.rating.\(UUID().uuidString)"
    let defaults: UserDefaults
    let transport = RatingFixtureTransport()
    let effects = SettingsFixtureEffects()
    let usage: UsageCollection
    let settings: SettingsCoordinator
    init() throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: domain))
        let transport = transport
        usage = UsageCollection(defaults: defaults) { identity in
            try PostHogClient(projectToken: "phc_fixture", identity: identity, transport: transport)
        }
        settings = SettingsCoordinator(preferences: PreferenceStore(defaults: defaults, domain: domain, evidence: .init()),
                                       usage: usage, version: .init(), effects: effects)
    }
    func close() { settings.close(); defaults.removePersistentDomain(forName: domain) }
    func open() throws -> FeedbackRatingController {
        settings.show(.about)
        let button = try #require(SettingsCoordinatorTests.find("about.feedback.rate") as? NSButton)
        button.performClick(nil)
        return try #require(settings.ratingController)
    }
    static func control<T: NSControl>(_ id: String, in controller: FeedbackRatingController, as type: T.Type) throws -> T {
        @MainActor func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap(walk).first
        }
        return try #require(walk(controller.view) as? T)
    }
    static func choose(_ index: Int, in controller: FeedbackRatingController) throws {
        let ratings = try control("feedback.rating", in: controller, as: NSSegmentedControl.self)
        ratings.selectedSegment = index
        _ = ratings.sendAction(ratings.action, to: ratings.target)
    }
}

extension SettingsCoordinatorTests {
    @Test @MainActor func ratingFormDoesNotEnableCollectionAndClosesWithItsPage() throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        let sheet = try fixture.open()
        #expect(!sheet.state.collectionEnabled)
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        #expect(!submit.isEnabled)
        submit.performClick(nil)
        #expect(fixture.settings.ratingSend == nil)
        #expect(fixture.defaults.object(forKey: UsageCollection.identityKey) == nil)
        fixture.settings.show(.general)
        #expect(fixture.settings.ratingController == nil)
        #expect(!fixture.usage.enabled)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func ratingControlsWaitForAckAndIgnoreRepeatedSubmit() async throws {
        FileHandle.standardError.write(Data("rating-test: begin\n".utf8))
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        FileHandle.standardError.write(Data("rating-test: enabled\n".utf8))
        let sheet = try fixture.open()
        FileHandle.standardError.write(Data("rating-test: opened\n".utf8))
        try RatingFixture.choose(3, in: sheet)
        FileHandle.standardError.write(Data("rating-test: chosen\n".utf8))
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        submit.performClick(nil)
        FileHandle.standardError.write(Data("rating-test: submitted\n".utf8))
        #expect(sheet.state.submission == .sending)
        #expect(!submit.isEnabled)
        _ = submit.sendAction(submit.action, to: submit.target)
        var started = await fixture.transport.started.makeAsyncIterator()
        FileHandle.standardError.write(Data("rating-test: awaiting transport\n".utf8))
        _ = await started.next()
        FileHandle.standardError.write(Data("rating-test: transport started\n".utf8))
        #expect(await fixture.transport.snapshot().count == 1)
        let send = try #require(fixture.settings.ratingSend)
        await fixture.transport.release()
        await send.value
        #expect(sheet.state.submission == .sent)
        let done = try RatingFixture.control("feedback.done", in: sheet, as: NSButton.self)
        #expect(!done.isHidden)
        #expect(done.keyEquivalent == "\r")
        #expect(submit.isHidden && submit.keyEquivalent.isEmpty)
        sheet.cancelOperation(nil)
        #expect(fixture.settings.ratingController == nil)
        await fixture.usage.setEnabled(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func ratingRetriesReuseOnlyTheSameRatingToken() async throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        let sheet = try fixture.open()
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        var started = await fixture.transport.started.makeAsyncIterator()
        for index in [2, 2, 4] {
            try RatingFixture.choose(index, in: sheet)
            submit.performClick(nil)
            let send = try #require(fixture.settings.ratingSend)
            _ = await started.next()
            await fixture.transport.release(accepted: false)
            await send.value
            #expect(sheet.state.submission == .failed(.unconfirmed))
        }
        let requests = await fixture.transport.snapshot()
        #expect(requests.count == 3)
        func uuid(_ request: UsageRequest) throws -> String {
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let batch = try #require(body["batch"] as? [[String: Any]])
            return try #require(batch.first?["uuid"] as? String)
        }
        #expect(try uuid(requests[0]) == uuid(requests[1]))
        #expect(try uuid(requests[1]) != uuid(requests[2]))
        await fixture.usage.setEnabled(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func aClosedRatingCannotUpdateANewVisitAfterItsLateAck() async throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        let previous = try fixture.open()
        try RatingFixture.choose(1, in: previous)
        try RatingFixture.control("feedback.submit", in: previous, as: NSButton.self).performClick(nil)
        var started = await fixture.transport.started.makeAsyncIterator()
        _ = await started.next()
        let send = try #require(fixture.settings.ratingSend)
        fixture.settings.close()
        #expect(send.isCancelled)
        #expect(fixture.settings.ratingController == nil)
        let fresh = try fixture.open()
        #expect(fresh !== previous)
        await fixture.transport.release()
        await send.value
        #expect(fixture.settings.ratingController === fresh)
        #expect(fresh.state.submission == .ready)
        #expect(previous.state.submission == .sending)
        #expect(fixture.settings.ratingSend == nil)
        await fixture.usage.setEnabled(false)
    }
}
