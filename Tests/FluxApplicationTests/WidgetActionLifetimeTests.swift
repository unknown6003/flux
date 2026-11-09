import AppKit
import Testing
import FluxCore
import FluxPlatform
@testable import FluxApplication
@testable import FluxUI

@MainActor private final class WidgetActionEffects: WidgetEffects {
    var retries = 0
    func requestAccess(_ permission: WidgetPermission) async { Issue.record("Unexpected access request") }
    func openSettings(_ permission: WidgetPermission) { Issue.record("Unexpected Settings") }
    func retry(_ service: FeatureService) { retries += 1 }
    func report(_ failure: WidgetFailure) { Issue.record("Unexpected failure") }
    func widgetEvent(_ event: WidgetEvent) { Issue.record("Unexpected private event") }
}

struct WidgetActionLifetimeTests {

    @Test @MainActor func aRetainedOldWidgetCannotActAfterDismissOrOnANewVisit() throws {
        _ = NSApplication.shared
        let domain = "org.fluxfixture.widget-action.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = PreferenceStore(defaults: defaults, domain: domain, evidence: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-widget-action-\(UUID())")
        let effects = WidgetActionEffects()
        let widgets = WidgetCoordinator(preferences: preferences, shelf: ShelfFiles(root: root),
            clipboard: ClipboardRepository(historyURL: root.appendingPathComponent("clipboard.json")),
            pasteboard: PasteboardChannel(), mediaScript: root, mediaFramework: root, effects: effects)
        // A retained SwiftUI view keeps its model, so the action itself must
        // be dead once its visit ends.
        let old = try #require(widgets.makeWidget(.nowPlaying) as? NowPlayingWidgetController).model.onAction
        old(.checkAgain)
        #expect(effects.retries == 1)
        widgets.dismiss()
        old(.checkAgain)
        #expect(effects.retries == 1)
        let current = try #require(widgets.makeWidget(.nowPlaying) as? NowPlayingWidgetController)
        old(.checkAgain)
        #expect(effects.retries == 1)
        current.model.onAction(.checkAgain)
        #expect(effects.retries == 2)
        widgets.dismiss()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
