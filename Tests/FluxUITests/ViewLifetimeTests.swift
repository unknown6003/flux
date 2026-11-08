import AppKit
import Testing
import FluxCore
@testable import FluxUI

@Suite(.serialized)
struct ViewLifetimeTests {
    @Test @MainActor func settingsBuildsOnePageAndReleasesItOnSwitchAndClose() {
        _ = NSApplication.shared
        var made: [SettingsPage] = []
        var stopped: [SettingsPage] = []
        weak var previous: NSViewController?
        let settings = autoreleasepool {
            SettingsWindowController { page in
                made.append(page)
                let controller = NSViewController()
                controller.view = NSView()
                previous = controller
                return controller
            }
        }
        settings.onPageWillDisappear = { stopped.append($0) }
        autoreleasepool {
            #expect(made == [.general])
            #expect(previous != nil)
            settings.select(.menuBar, focusPage: false)
            #expect(made == [.general, .menuBar])
            #expect(stopped == [.general])
            settings.select(.menuBar, focusPage: false)
            #expect(made.count == 2)
            settings.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        #expect(stopped == [.general, .menuBar])
        #expect(previous == nil)
        #expect(settings.currentPage == nil)
    }

    @Test @MainActor func removingVisibleMirrorStopsItBeforeReleasingItsView() {
        _ = NSApplication.shared
        var calls: [String] = []
        weak var mirror: NSViewController?
        let panel = NotchPanelController(
            widgets: [.mirror, .shelf],
            geometry: .init(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), cameraWidth: 180, topInset: 32)
        ) { widget in
            calls.append("make.\(widget.rawValue)")
            let controller = NSViewController()
            controller.view = NSView()
            if widget == .mirror { mirror = controller }
            return controller
        }
        autoreleasepool {
            _ = panel.view
            panel.show(.mirror)
            panel.onWillSwitch = { from, to in
                #expect(from == .mirror)
                #expect(to == .shelf)
                #expect(mirror != nil)
                calls.append("stop.mirror")
            }
            panel.setWidgets([.shelf, .shelf])
        }
        #expect(calls == ["make.mirror", "stop.mirror", "make.shelf"])
        #expect(mirror == nil)
        #expect(panel.widgets == [.shelf])
        #expect(panel.children.count == 1)
        panel.onWillDismiss = { widget in
            #expect(widget == .shelf)
            #expect(panel.children.count == 1)
            calls.append("stop.shelf")
        }
        panel.setWidgets([])
        #expect(calls.last == "stop.shelf")
        #expect(panel.children.isEmpty)
        #expect(panel.current == nil)
        panel.onWillDismiss = nil
    }

    @Test @MainActor func analyticsStartsOffAndDoesNotInvokeCallbacksDuringReadback() {
        _ = NSApplication.shared
        let view = AnalyticsSettingsView()
        var requested = false
        view.onSetEnabled = { _ in requested = true }
        view.onResetID = { requested = true }
        #expect(view.toggle.state == .off)
        view.update(.working)
        #expect(!view.toggle.isEnabled)
        view.update(.on)
        #expect(view.toggle.state == .on)
        view.update(.off)
        #expect(view.toggle.state == .off)
        #expect(!requested)
    }

    @Test @MainActor func generalReadbackIsSilentAndItsAnalyticsControlForwardsTypedAction() throws {
        _ = NSApplication.shared
        var requested: [GeneralPreferencesAction] = []
        func state(_ analytics: AnalyticsStatus) -> GeneralPreferencesState {
            .init(launchAtLoginRequested: false, loginStatus: .disabled, hotkeysEnabled: true,
                  revealShortcut: .init(keyCode: 3, carbonModifiers: 6400),
                  notchShortcut: .init(keyCode: 45, carbonModifiers: 6400),
                  appearance: .system, automaticUpdateChecks: true, analytics: analytics)
        }
        let page = GeneralPreferencesController(state: state(.off)) { requested.append($0) }
        _ = page.view
        page.update(state: state(.on))
        #expect(requested.isEmpty)
        let toggle = try #require(Self.find("analytics.enabled", in: page.view) as? NSSwitch)
        #expect(toggle.state == .on)
        toggle.state = .off
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        #expect(requested == [.setAnalyticsEnabled(false)])
    }

    @MainActor private static func find(_ id: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == id { return root }
        for view in root.subviews {
            if let found = find(id, in: view) { return found }
        }
        return nil
    }
}
