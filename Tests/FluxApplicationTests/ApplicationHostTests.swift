import AppKit
import Foundation
import Testing
import FluxCore
import FluxPlatform
import FluxUI
@testable import FluxApplication

@MainActor private final class HostTrace { var calls: [String] = [] }

@MainActor private final class HostFixtureSession: HostSession {
    let files: ApplicationFiles
    let preferences: PreferenceStore
    let usage: UsageCollection
    let version = ApplicationVersion()
    let previousSessionWasUnclean = false
    let previousCameraWasRunning = false
    let trace: HostTrace
    init(root: URL, defaults: UserDefaults, domain: String, trace: HostTrace) throws {
        files = ApplicationFiles(applicationSupport: root)
        preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(false, for: Preferences.notchEnabled)
        try preferences.set(false, for: Preferences.automaticUpdateChecks)
        try preferences.set(false, for: Preferences.enableHotkey)
        try preferences.set(3, for: Preferences.shelfExpiryDays)
        usage = UsageCollection(defaults: defaults) { _ in
            Issue.record("An off analytics client was constructed")
            throw FixtureError.unexpected
        }
        self.trace = trace
    }
    func markReady() { trace.calls.append("session.ready") }
    func cameraIsRunning(_ running: Bool) { #expect(!running) }
    func finish() { trace.calls.append("session.finish") }
}

private enum FixtureError: Error { case unexpected }

@MainActor private final class HostFixtureMenu: MenuBarService {
    var onAction: (@MainActor (MenuBarAction) -> Void)?
    var onChange: (@MainActor () -> Void)?
    var onOverflow: (@MainActor (Int) -> Void)?
    var state: MenuBarPageState { .init(mode: .paused) }
    let trace: HostTrace
    init(_ trace: HostTrace) { self.trace = trace }
    func start() { trace.calls.append("menu.start"); onOverflow?(3) }
    func stop() async throws { trace.calls.append("menu.stop") }
    func setEditorVisible(_ visible: Bool) { trace.calls.append("editor.\(visible)") }
    private func unexpected() { Issue.record("An unrelated menu action ran") }
    func refresh() { unexpected() }
    func configure() { unexpected() }
    func toggle() { unexpected() }
    func showAll() { unexpected() }
    func assign(_ application: ApplicationID, to group: MenuBarGroup) { unexpected() }
    func beginArrange() { unexpected() }
    func endArrange() { unexpected() }
    func showRealIcons() { unexpected() }
    func checkAccessibility() { unexpected() }
    func reviewIdentity(_ application: ApplicationID) { unexpected() }
    func setCompactSpacing(_ enabled: Bool) { unexpected() }
}

@MainActor private final class HostFixtureLockScreen: LockScreenService {
    var onChange: (@MainActor () -> Void)?
    var onTransport: (@MainActor (LockScreenTransportAction) -> Void)?
    var capability: LockScreenCapability { .unavailable }
    var failureCode: String? { nil }
    func makeHandle() throws -> any FeatureServiceHandle {
        Issue.record("An off lock-screen service was constructed")
        throw FixtureError.unexpected
    }
    func configure() { Issue.record("Unexpected lock-screen configure") }
    func checkAgain() { Issue.record("Unexpected lock-screen probe") }
    func setPhase(_ phase: SessionPhase) {}
    func receive(_ event: WidgetEvent) { Issue.record("An off widget emitted private content") }
    func updateActivity(_ item: ActivityItem?) { #expect(item == nil) }
    func stop() {}
}

@Suite(.serialized)
struct ApplicationHostTests {
    @Test @MainActor func offFeatureStartupAndSettingsVisitsUseTheRealHostAndStopBeforeSessionFinish() async throws {
        _ = NSApplication.shared
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        let domain = "org.fluxfixture.host.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-host-\(UUID())")
        let trace = HostTrace()
        let session = try HostFixtureSession(root: root, defaults: defaults, domain: domain, trace: trace)
        let menu = HostFixtureMenu(trace)
        let host = ApplicationHost(owner: session, menuBar: menu, lockScreen: HostFixtureLockScreen(),
            failure: { _ in Issue.record("Unexpected host failure") }, quit: { Issue.record("Unexpected quit") })
        try host.start()
        #expect(trace.calls == ["menu.start", "session.ready"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        host.showSettings(.menuBar)
        #expect(trace.calls.last == "editor.true")
        await host.stop()
        #expect(trace.calls == ["menu.start", "session.ready", "editor.true", "editor.false", "menu.stop", "session.finish"])
        #expect(menu.onAction == nil)
        #expect(menu.onOverflow == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(defaults.object(forKey: UsageCollection.identityKey) == nil)
    }
}
