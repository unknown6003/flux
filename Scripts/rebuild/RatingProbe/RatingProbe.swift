import AppKit
import Foundation
import Darwin
import FluxCore
import FluxUI
#if DEBUG
@testable import FluxApplication

private enum RatingProbeFailure: Error { case missingFixture, assertion }
private func requireValue<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        FileHandle.standardError.write(Data("Missing native fixture at \(file):\(line)\n".utf8))
        throw RatingProbeFailure.missingFixture
    }
    return value
}
private func requireTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard value else {
        FileHandle.standardError.write(Data("Native assertion at \(file):\(line)\n".utf8))
        throw RatingProbeFailure.assertion
    }
}

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
    private func unexpected() { failures.append(.saveFailed) }
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
        defaults = try requireValue(UserDefaults(suiteName: domain))
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
        let button = try requireValue(RatingScenarios.find("about.feedback.rate") as? NSButton)
        button.performClick(nil)
        return try requireValue(settings.ratingController)
    }
    static func control<T: NSControl>(_ id: String, in controller: FeedbackRatingController, as type: T.Type) throws -> T {
        @MainActor func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap(walk).first
        }
        return try requireValue(walk(controller.view) as? T)
    }
    static func choose(_ index: Int, in controller: FeedbackRatingController) throws {
        let ratings = try control("feedback.rating", in: controller, as: NSSegmentedControl.self)
        ratings.selectedSegment = index
        _ = ratings.sendAction(ratings.action, to: ratings.target)
    }
}

@MainActor private enum RatingScenarios {
    static func identityReviewNeedsAnExplicitClickAndCancelsWithItsTask() async throws {
        let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 680, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let prompt = MenuBarIdentityPrompt(parentWindow: { window })
        func waitForSheet(_ present: Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while (window.attachedSheet != nil) != present {
                guard ContinuousClock.now < deadline else {
                    FileHandle.standardError.write(Data("Identity sheet presence expected \(present)\n".utf8))
                    throw RatingProbeFailure.missingFixture
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func button(_ title: String) throws -> NSButton {
            func walk(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == title { return button }
                return view.subviews.lazy.compactMap(walk).first
            }
            return try requireValue(window.attachedSheet?.contentView.flatMap(walk))
        }
        let cancelled = Task { @MainActor in await prompt.confirm(name: "Example") }
        try await waitForSheet(true)
        let approve = try button("Use This Copy")
        let cancel = try button("Cancel")
        try requireTrue(approve.keyEquivalent.isEmpty && cancel.keyEquivalent == "\r")
        try requireTrue(window.attachedSheet?.defaultButtonCell === cancel.cell)
        if let content = window.attachedSheet?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: "build/native-test-logs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("identity-review.png"))
        }
        cancel.performClick(nil)
        try requireTrue(await cancelled.value == false)
        try await waitForSheet(false)
        window.makeKeyAndOrderFront(nil)
        let accepted = Task { @MainActor in await prompt.confirm(name: "Example") }
        try await waitForSheet(true)
        try button("Use This Copy").performClick(nil)
        try requireTrue(await accepted.value)
        try await waitForSheet(false)
        window.makeKeyAndOrderFront(nil)
        let stopped = Task { @MainActor in await prompt.confirm(name: "Example") }
        try await waitForSheet(true)
        stopped.cancel()
        try requireTrue(await stopped.value == false)
        try await waitForSheet(false)
    }

    @MainActor fileprivate static func find(_ id: String) -> NSView? {
        @MainActor func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap(walk).first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(walk) }.first
    }


    static func ratingFormDoesNotEnableCollectionAndClosesWithItsPage() throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        let sheet = try fixture.open()
        try requireTrue(!sheet.state.collectionEnabled)
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        try requireTrue(!submit.isEnabled)
        submit.performClick(nil)
        try requireTrue(fixture.settings.ratingSend == nil)
        try requireTrue(fixture.defaults.object(forKey: UsageCollection.identityKey) == nil)
        fixture.settings.show(.general)
        try requireTrue(fixture.settings.ratingController == nil)
        try requireTrue(!fixture.usage.enabled)
    }

    static func ratingControlsWaitForAckAndIgnoreRepeatedSubmit() async throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        let sheet = try fixture.open()
        try RatingFixture.choose(3, in: sheet)
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        submit.performClick(nil)
        try requireTrue(sheet.state.submission == .sending)
        try requireTrue(!submit.isEnabled)
        _ = submit.sendAction(submit.action, to: submit.target)
        var started = await fixture.transport.started.makeAsyncIterator()
        _ = await started.next()
        try requireTrue(await fixture.transport.snapshot().count == 1)
        let send = try requireValue(fixture.settings.ratingSend)
        await fixture.transport.release()
        await send.value
        try requireTrue(sheet.state.submission == .sent)
        let done = try RatingFixture.control("feedback.done", in: sheet, as: NSButton.self)
        try requireTrue(!done.isHidden)
        try requireTrue(done.keyEquivalent == "\r")
        try requireTrue(submit.isHidden && submit.keyEquivalent.isEmpty)
        sheet.cancelOperation(nil)
        try requireTrue(fixture.settings.ratingController == nil)
        await fixture.usage.setEnabled(false)
    }

    static func ratingRetriesReuseOnlyTheSameRatingToken() async throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        let sheet = try fixture.open()
        let submit = try RatingFixture.control("feedback.submit", in: sheet, as: NSButton.self)
        var started = await fixture.transport.started.makeAsyncIterator()
        for index in [2, 2, 4] {
            try RatingFixture.choose(index, in: sheet)
            submit.performClick(nil)
            let send = try requireValue(fixture.settings.ratingSend)
            _ = await started.next()
            await fixture.transport.release(accepted: false)
            await send.value
            try requireTrue(sheet.state.submission == .failed(.unconfirmed))
        }
        let requests = await fixture.transport.snapshot()
        try requireTrue(requests.count == 3)
        func uuid(_ request: UsageRequest) throws -> String {
            let body = try requireValue(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let batch = try requireValue(body["batch"] as? [[String: Any]])
            return try requireValue(batch.first?["uuid"] as? String)
        }
        try requireTrue(try uuid(requests[0]) == uuid(requests[1]))
        try requireTrue(try uuid(requests[1]) != uuid(requests[2]))
        await fixture.usage.setEnabled(false)
    }

    static func aClosedRatingCannotUpdateANewVisitAfterItsLateAck() async throws {
        let fixture = try RatingFixture()
        defer { fixture.close() }
        await fixture.usage.setEnabled(true)
        let previous = try fixture.open()
        try RatingFixture.choose(1, in: previous)
        try RatingFixture.control("feedback.submit", in: previous, as: NSButton.self).performClick(nil)
        var started = await fixture.transport.started.makeAsyncIterator()
        _ = await started.next()
        let send = try requireValue(fixture.settings.ratingSend)
        fixture.settings.close()
        try requireTrue(send.isCancelled)
        try requireTrue(fixture.settings.ratingController == nil)
        let fresh = try fixture.open()
        try requireTrue(fresh !== previous)
        await fixture.transport.release()
        await send.value
        try requireTrue(fixture.settings.ratingController === fresh)
        try requireTrue(fresh.state.submission == .ready)
        try requireTrue(previous.state.submission == .sending)
        try requireTrue(fixture.settings.ratingSend == nil)
        await fixture.usage.setEnabled(false)
    }
}


@MainActor private final class RatingProbeDelegate: NSObject, NSApplicationDelegate {
    var passed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try RatingScenarios.ratingFormDoesNotEnableCollectionAndClosesWithItsPage()
                try await RatingScenarios.ratingControlsWaitForAckAndIgnoreRepeatedSubmit()
                try await RatingScenarios.ratingRetriesReuseOnlyTheSameRatingToken()
                try await RatingScenarios.aClosedRatingCannotUpdateANewVisitAfterItsLateAck()
                try await RatingScenarios.identityReviewNeedsAnExplicitClickAndCancelsWithItsTask()
                passed = true
                print("{\"nativeRatingScenariosPassed\":4,\"nativeIdentityScenariosPassed\":1}")
            } catch {
                FileHandle.standardError.write(Data("Native rating scenario failed\n".utf8))
            }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
        }
    }
}

@main private struct RatingProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = RatingProbeDelegate()
        app.delegate = delegate
        app.run()
        exit(delegate.passed ? 0 : 1)
    }
}
#else
@main private struct RatingProbe {
    static func main() { fatalError("The native rating fixture runs only in a Debug build") }
}
#endif
