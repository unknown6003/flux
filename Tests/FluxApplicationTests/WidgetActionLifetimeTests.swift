import AppKit
import Testing
import FluxCore
import FluxPlatform
@testable import FluxApplication

@MainActor private final class WidgetActionEffects: WidgetEffects {
    var retries = 0
    func requestAccess(_ permission: WidgetPermission) async { Issue.record("Unexpected access request") }
    func openSettings(_ permission: WidgetPermission) { Issue.record("Unexpected Settings") }
    func retry(_ service: FeatureService) { retries += 1 }
    func report(_ failure: WidgetFailure) { Issue.record("Unexpected failure") }
    func widgetEvent(_ event: WidgetEvent) { Issue.record("Unexpected private event") }
}

struct WidgetActionLifetimeTests {
    @MainActor private func retryButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == "Check Again" { return button }
        return view.subviews.lazy.compactMap { retryButton(in: $0) }.first
    }

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
        let old = widgets.makeWidget(.nowPlaying)
        let button = try #require(retryButton(in: old.view))
        button.performClick(nil)
        #expect(effects.retries == 1)
        widgets.dismiss()
        button.performClick(nil)
        #expect(effects.retries == 1)
        let current = widgets.makeWidget(.nowPlaying)
        button.performClick(nil)
        #expect(effects.retries == 1)
        try #require(retryButton(in: current.view)).performClick(nil)
        #expect(effects.retries == 2)
        widgets.dismiss()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
