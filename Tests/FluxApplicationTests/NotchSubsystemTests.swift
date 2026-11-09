import AppKit
import Foundation
import Testing
import FluxCore
@testable import FluxApplication

@Suite(.serialized)
struct NotchSubsystemTests {
    @Test @MainActor func aDisabledNotchDoesNotConstructAnAdditionalFeatureOrTouchStoredFiles() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.subsystem.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(false, for: Preferences.notchEnabled)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-subsystem-\(UUID())")
        enum Unexpected: Error { case service }
        let subsystem = NotchSubsystem(preferences: preferences, files: .init(applicationSupport: root),
            mediaScript: root.appendingPathComponent("not-opened.pl"), mediaFramework: root,
            callbacks: .init(report: { _ in Issue.record("An off feature failed") },
                contentChanged: { _ in Issue.record("An off feature emitted content") },
                phaseChanged: { _ in }, cameraRunning: { running in #expect(!running) },
                accessChanged: {}, timerCompleted: { _ in Issue.record("No timer expired") },
                activityChanged: { _ in },
                makeLockScreenService: { Issue.record("An off feature was constructed"); throw Unexpected.service }))
        defer { subsystem.stop() }
        subsystem.start()
        subsystem.refresh()
        #expect(subsystem.timerCount == 0)
        try subsystem.startTimer(minutes: 1)
        #expect(subsystem.timerCount == 1)
        subsystem.cancelAllTimers()
        #expect(subsystem.timerCount == 0)
        subsystem.stop()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
