import AppKit
import Testing
import FluxCore
@testable import FluxUI

@Suite(.serialized)
struct ViewLifetimeTests {
    @Test @MainActor func duoAddsAndRemovesOnlyTheCalendarCompanion() {
        _ = NSApplication.shared
        var made: [Widget] = []
        var companions: [Widget?] = []
        let panel = NotchPanelController(widgets: [.nowPlaying, .calendar, .mirror],
            geometry: .init(screenFrame: .init(x: 0, y: 0, width: 1728, height: 1117), cameraWidth: 180, topInset: 33)) { widget in
            made.append(widget)
            let child = NSViewController()
            child.view = NSView()
            return child
        }
        panel.onCompanionChange = { companions.append($0) }
        _ = panel.view
        panel.show(.nowPlaying)
        let primary = panel.children.first
        panel.setDuo(true)
        #expect(made == [.nowPlaying, .calendar])
        #expect(panel.children.count == 2)
        #expect(panel.children.first === primary)
        panel.setDuo(true)
        #expect(made.count == 2)
        panel.setDuo(false)
        #expect(panel.children.count == 1)
        #expect(panel.children.first === primary)
        panel.setDuo(true)
        panel.onWillDismiss = { _ in #expect(panel.children.count == 2) }
        panel.dismiss()
        #expect(panel.children.isEmpty)
        #expect(companions == [.calendar, nil, .calendar, nil])
        #expect(panel.current == nil)
    }

    @Test @MainActor func lateAppearanceCannotRestartADismissedWidget() {
        _ = NSApplication.shared
        var made: [Widget] = []
        let panel = NotchPanelController(widgets: [.mirror, .shelf],
            geometry: .init(screenFrame: .init(x: 0, y: 0, width: 1728, height: 1117), cameraWidth: 180, topInset: 33)) { widget in
            made.append(widget)
            let child = NSViewController()
            child.view = NSView()
            return child
        }
        _ = panel.view
        panel.show(.mirror)
        panel.dismiss()
        panel.viewDidAppear()
        panel.show(.shelf)
        #expect(made == [.mirror])
        #expect(panel.current == nil)
        #expect(panel.children.isEmpty)
    }
    @Test @MainActor func malformedMediaTimesNeverOverflowClockFormatting() {
        #expect(NotchWidgetStyle.clock(.nan) == "0:00")
        #expect(NotchWidgetStyle.clock(.infinity) == "0:00")
        #expect(NotchWidgetStyle.clock(-10) == "0:00")
        #expect(NotchWidgetStyle.clock(65) == "1:05")
        #expect(!NotchWidgetStyle.clock(.greatestFiniteMagnitude).isEmpty)
    }

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

    @Test @MainActor func generalReadbackIsSilentAndHasNoAnalyticsControl() throws {
        _ = NSApplication.shared
        var requested: [GeneralPreferencesAction] = []
        func state(hotkeys: Bool) -> GeneralPreferencesState {
            .init(launchAtLoginRequested: false, loginStatus: .disabled, hotkeysEnabled: hotkeys,
                  revealShortcut: .init(keyCode: 3, carbonModifiers: 6400),
                  notchShortcut: .init(keyCode: 45, carbonModifiers: 6400),
                  appearance: .system, permissions: [.init(kind: .accessibility, status: .allowed)])
        }
        let page = GeneralPreferencesController(state: state(hotkeys: false)) { requested.append($0) }
        _ = page.view
        page.update(state: state(hotkeys: true))
        #expect(requested.isEmpty)
        #expect(Self.find("analytics.enabled", in: page.view) == nil)
        #expect(Self.find("analytics.reset", in: page.view) == nil)
        let hotkeys = try #require(Self.find("general.hotkeys", in: page.view) as? NSSwitch)
        #expect(hotkeys.state == .on)
        hotkeys.state = .off
        _ = hotkeys.sendAction(hotkeys.action, to: hotkeys.target)
        #expect(requested == [.setHotkeysEnabled(false)])
    }

    @Test @MainActor func aboutAutomaticUpdateSwitchSendsItsAction() throws {
        _ = NSApplication.shared
        var requested: [AboutPreferencesAction] = []
        let page = AboutPreferencesController(state: .init(version: "1", build: "1", automaticUpdateChecks: true)) {
            requested.append($0)
        }
        _ = page.view
        let auto = try #require(Self.find("about.updates.auto", in: page.view) as? NSSwitch)
        #expect(auto.state == .on)
        auto.state = .off
        _ = auto.sendAction(auto.action, to: auto.target)
        #expect(requested == [.setAutomaticUpdateChecks(false)])
    }

    @Test @MainActor func settingsWindowUsesSystemSettingsSizesAndSidebarOrder() throws {
        _ = NSApplication.shared
        let settings = SettingsWindowController { _ in
            let controller = NSViewController()
            controller.view = NSView()
            return controller
        }
        defer { settings.close() }
        let window = try #require(settings.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == SettingsWindowController.defaultSize)
        #expect(window.contentMinSize == SettingsWindowController.minimumSize)
        #expect(window.title == SettingsPage.general.title)
        #expect(SettingsPage.allCases.first == .general)
        #expect(SettingsPage.allCases.last == .about)
    }

    @Test @MainActor func closedSettingsReleasesItsWindowAndViews() {
        _ = NSApplication.shared
        weak var controller: SettingsWindowController?
        weak var window: NSWindow?
        weak var page: NSView?
        autoreleasepool {
            let settings = SettingsWindowController(initialPage: .about) { _ in
                AboutPreferencesController(state: .init(version: "1", build: "1"), onAction: { _ in })
            }
            controller = settings
            window = settings.window
            page = settings.window?.contentView
            settings.close()
        }
        #expect(controller == nil)
        #expect(window == nil)
        #expect(page == nil)
    }

    @Test @MainActor func rowControlsLineUpAndNeverCoverTheirText() throws {
        _ = NSApplication.shared
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["System", "Light", "Dark"])
        let button = NSButton(title: "Open Settings", target: nil, action: nil)
        let rows = [
            FluxUIStyle.row("Short", control: toggle),
            FluxUIStyle.row("A much longer title that has to wrap before it reaches the control",
                            helper: "And a helper line that is also long enough to wrap in a narrow window.", control: popup),
            FluxUIStyle.row("Middle", helper: "Help.", control: button),
        ]
        let section = FluxUIStyle.section("Title", rows, footer: "Footer text.")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        section.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            section.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let controls: [NSView] = [toggle, popup, button]
        let edges = controls.map { $0.convert($0.bounds, to: root).maxX }
        #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.5 })
        for (row, control) in zip(rows, controls) {
            let frame = control.convert(control.bounds, to: root)
            let texts = row.subviews.flatMap { Self.labels(in: $0) }
            #expect(!texts.isEmpty)
            for text in texts {
                let box = text.convert(text.bounds, to: root)
                #expect(box.maxX <= frame.minX - 8)
                #expect(box.height >= text.intrinsicContentSize.height - 1)
            }
            #expect(frame.minY >= row.convert(row.bounds, to: root).minY)
        }
    }

    @Test @MainActor func shortAndLongSettingsSectionsFillTheSameAvailableWidth() {
        _ = NSApplication.shared
        let short = FluxUIStyle.section("Short", [FluxUIStyle.label("A")])
        let long = FluxUIStyle.section("Long", [FluxUIStyle.label("A longer row of text that needs more width")])
        let stack = FluxUIStyle.vstack([short, long])
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        #expect(abs(short.frame.width - 480) < 1)
        #expect(abs(long.frame.width - 480) < 1)
        #expect(abs(short.frame.minX - long.frame.minX) < 1)
        #expect(short.frame.height > 30)
        #expect(long.frame.maxY <= short.frame.minY || short.frame.maxY <= long.frame.minY)
        window.close()
    }

    @MainActor private static func labels(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { labels(in: $0) }
    }

    @MainActor private static func find(_ id: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == id { return root }
        for view in root.subviews {
            if let found = find(id, in: view) { return found }
        }
        return nil
    }
}
