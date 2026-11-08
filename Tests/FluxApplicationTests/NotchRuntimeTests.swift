import AppKit
import Foundation
import Testing
import FluxCore
import FluxPlatform
@testable import FluxApplication

@MainActor private final class RuntimeLease: FeatureServiceHandle {
    private var stopped = false
    private let onStop: () -> Void
    init(onStop: @escaping () -> Void) { self.onStop = onStop }
    func stop() {
        guard !stopped else { return }
        stopped = true
        onStop()
    }
}

@Suite(.serialized)
struct NotchRuntimeTests {
    @Test @MainActor func lockStopsPrivateFeedsAndRetryReplacesAnExistingHandle() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        try preferences.set(true, for: Preferences.clipboardEnabled)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-runtime-\(UUID())")
        let files = ApplicationFiles(applicationSupport: root)
        var calls: [String] = []
        var camera: [Bool] = []
        let runtime = NotchRuntime(preferences: preferences, files: files,
            mediaScript: root.appendingPathComponent("not-opened.pl"),
            mediaFramework: root.appendingPathComponent("not-opened.framework"),
            callbacks: .init(report: { _ in Issue.record("Unexpected service failure") },
                event: { _ in }, battery: { _ in }, volume: { _ in }, device: { _ in }, compactAction: { _ in },
                cameraRunning: { camera.append($0) }, accessChanged: {}, phaseChanged: { _ in },
                presenting: { _ in }, environmentChanged: {},
                makeAdditionalService: { _ in throw TestFailure.unexpectedFactory }),
            permission: { _ in .notAllowed }, serviceOverride: { service in
                calls.append("start.\(service)")
                return RuntimeLease { calls.append("stop.\(service)") }
            })
        defer { runtime.stop() }
        #expect(calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        runtime.begin(phase: .unlocked)
        #expect(runtime.activeServices == [.clipboard, .media, .battery, .devices, .volume])
        calls.removeAll()
        runtime.retry(.media)
        #expect(calls == ["stop.media", "start.media"])
        calls.removeAll()
        runtime.setPhase(.locked)
        #expect(runtime.activeServices.isEmpty)
        #expect(calls.filter { $0.hasPrefix("stop.") }.count == 5)
        #expect(!calls.contains { $0.hasPrefix("start.") })
        #expect(runtime.presentation == .hidden)
        runtime.setPhase(.unlocked)
        #expect(runtime.activeServices.count == 5)
        runtime.stop()
        #expect(runtime.activeServices.isEmpty)
        #expect(camera.last == false)
        let stoppedCount = calls.count
        runtime.setPhase(.unlocked)
        runtime.retry(.media)
        #expect(calls.count == stoppedCount)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test @MainActor func oneMissingServiceDoesNotBlockOtherEnabledServices() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.runtime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-runtime-\(UUID())")
        var failures: [FeatureService] = []
        let runtime = NotchRuntime(preferences: preferences, files: .init(applicationSupport: root),
            mediaScript: root, mediaFramework: root,
            callbacks: .init(report: {
                if case .service(let service) = $0 { failures.append(service) }
                else { Issue.record("Unexpected widget failure") }
            }, event: { _ in }, battery: { _ in }, volume: { _ in }, device: { _ in }, compactAction: { _ in },
                cameraRunning: { _ in }, accessChanged: {}, phaseChanged: { _ in },
                presenting: { _ in }, environmentChanged: {},
                makeAdditionalService: { _ in throw TestFailure.unexpectedFactory }),
            permission: { _ in .notAllowed }, serviceOverride: { service in
                if service == .devices { throw TestFailure.unexpectedFactory }
                return RuntimeLease(onStop: {})
            })
        defer { runtime.stop() }
        runtime.begin(phase: .unlocked)
        #expect(failures == [.devices])
        #expect(runtime.activeServices == [.media, .battery, .volume])
    }

    private enum TestFailure: Error { case unexpectedFactory }
}
