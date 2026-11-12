import AppKit
import FluxApplication
import FluxCore
import FluxPlatform
import FluxUI

/// CI only. Drives the Menu Bar layout editor against the real menu bar:
/// plain mouse gestures enter the tile's native dragging session, then the
/// real page action, service, planner and physical status-item Cmd-drag.
///
/// Usage: FluxMenuBarArrangeProbe <left fixture id> <right fixture id> <group fixture id>
/// It prints `STEP <name> <json>` lines and waits for one stdin line after
/// each, so the caller can capture the screen. It exits 0 when every step
/// reports a finished move, and 1 on any failure or deadline.
@main @MainActor struct MenuBarArrangeProbe {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let first = ApplicationID(rawValue: arguments[1]),
              let second = ApplicationID(rawValue: arguments[2]),
              let grouped = ApplicationID(rawValue: arguments[3]),
              let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.flux.") else {
            fail("usage: FluxMenuBarArrangeProbe <left> <right> <group> from a com.flux. bundle")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.set(false, forKey: "flux.autoRehide")
        Task { @MainActor in
            await run(domain: domain, first: first, second: second, grouped: grouped)
        }
        NSApp.run()
    }

    static func run(domain: String, first: ApplicationID, second: ApplicationID, grouped: ApplicationID) async {
        let preferences = PreferenceStore(defaults: .standard, domain: domain, evidence: .init())
        let hider = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? PerApplicationHider() : nil
        let service = PositionMenuBarService(defaults: .standard, domain: domain, preferences: preferences,
            hidingSupport: PositionMenuBarHidingSupport.current(hider: hider), perApplicationHider: hider)
        var requests: [MenuBarItemMove] = []
        let actions = MenuBarPageActions(assign: { service.assign($0, to: $1) }, beginArrange: {}, endArrange: {},
            showRealIcons: {}, refresh: { service.refresh() }, openAccessibilitySettings: {}, checkAccessibility: {},
            reviewIdentity: { _ in }, setOption: { _ in }, moveItem: { requests.append($0); service.moveItem($0) })
        let page = MenuBarPreferencesController(state: service.state, actions: actions)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 680, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = page
        // The page is a scroll view with no fitting size; keep the window readable.
        window.setContentSize(NSSize(width: 680, height: 700))
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 40))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        service.onChange = { page.update(service.state) }
        service.start()
        service.setEditorVisible(true)

        func tile(_ application: ApplicationID) -> MenuBarLayoutTile? {
            service.state.tiles.first { $0.id.application == application }
        }
        func describe() -> String {
            let tiles = service.state.tiles.map { tile in
                "{\"id\":\"\(tile.id.application.rawValue)\",\"group\":\"\(tile.group.rawValue)\"}"
            }
            return "{\"mode\":\"\(service.state.mode)\",\"status\":\"\(service.state.moveStatus.map { "\($0)" } ?? "")\",\"tiles\":[\(tiles.joined(separator: ","))]}"
        }
        func wait(_ seconds: Double, _ label: String, until done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() {
                guard Date() < deadline else { fail("\(label) timed out: \(describe())") }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func step(_ name: String) async {
            print("STEP \(name) \(describe())")
            fflush(stdout)
            // Read off the main thread, so status items and the hider keep running.
            let line = await Task.detached { readLine() }.value
            guard line != nil else { fail("the caller closed stdin") }
        }
        func view(named identifier: String, in root: NSView) -> NSView? {
            if root.accessibilityIdentifier() == identifier { return root }
            for child in root.subviews {
                if let found = view(named: identifier, in: child) { return found }
            }
            return nil
        }
        func tileView(_ application: ApplicationID) -> NSView {
            guard let id = tile(application)?.id,
                  let result = view(named: "flux.menuBar.item." + id.token, in: page.view) else {
                fail("missing tile view for \(application.rawValue)")
            }
            return result
        }
        func screenPoint(_ view: NSView, at local: CGPoint) -> CGPoint {
            view.scrollToVisible(view.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            guard view.window === window, view.visibleRect.contains(local), !view.isHiddenOrHasHiddenAncestor,
                  let primary = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
                  }), window.screen === primary else { fail("gesture point is not visible on the primary display") }
            let inWindow = view.convert(local, to: nil)
            guard let content = window.contentView,
                  let hit = content.hitTest(content.convert(inWindow, from: nil)),
                  hit === view || hit.isDescendant(of: view) else { fail("gesture point is covered") }
            let point = window.convertPoint(toScreen: inWindow)
            let display = CGDisplayBounds(CGMainDisplayID())
            return CGPoint(x: display.minX + point.x - primary.frame.minX,
                           y: display.minY + primary.frame.maxY - point.y)
        }
        func center(_ application: ApplicationID) -> CGPoint {
            let view = tileView(application)
            return screenPoint(view, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        func endOfStrip(_ group: MenuBarGroup) -> CGPoint {
            guard let flow = view(named: "flux.menuBar.drop." + group.rawValue, in: page.view) else {
                fail("missing drop strip \(group.rawValue)")
            }
            flow.scrollToVisible(flow.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            let tiles = flow.subviews.filter { $0.accessibilityIdentifier().hasPrefix("flux.menuBar.item.") }
            let point: CGPoint
            if let last = tiles.max(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
                point = CGPoint(x: min(flow.bounds.maxX - 4, last.frame.maxX + 3), y: last.frame.midY)
            } else {
                point = CGPoint(x: flow.bounds.midX, y: flow.bounds.midY)
            }
            return screenPoint(flow, at: point)
        }
        func drag(_ name: String, source: ApplicationID, to destination: () -> CGPoint, group: MenuBarGroup) async {
            await wait(10, "quiet before \(name)") { !service.state.isRefreshing && quietInput() }
            let target = destination()
            let start = center(source)
            let before = requests.count
            let expected = tile(source)!.id
            print("GESTURE \(name) source=\(source.rawValue) from=[\(start.x),\(start.y)] to=[\(target.x),\(target.y)]")
            fflush(stdout)
            // Only the worker sleeps/posts. AppKit's main loop must keep pumping
            // the native drag session, page actions, and the service's own drag.
            let posted = await Task.detached { plainMouseDrag(from: start, to: target) }.value
            guard posted else { fail("\(name) could not post an unmodified gesture") }
            await wait(5, "drop request \(name)") { requests.count > before }
            guard requests.count == before + 1, let request = requests.last,
                  request.item == expected, request.group == group, request.intent == .slot else {
                fail("\(name) did not send exactly one matching slot request")
            }
            await wait(40, "settled \(name)") {
                if case .moving = service.state.moveStatus { return false }
                return service.state.moveStatus != nil && !service.state.isRefreshing
            }
            guard case .moved = service.state.moveStatus, tile(source)?.group == group else {
                fail("\(name) failed: \(describe())")
            }
            guard quietInput() else { fail("\(name) left synthetic input held") }
        }

        await wait(5, "active editor") { NSApp.isActive && window.isKeyWindow }
        await wait(30, "inventory") {
            !service.state.isRefreshing && [first, second, grouped].allSatisfy { tile($0) != nil }
                && service.state.mode != .paused
        }
        print("READY \(describe())")
        fflush(stdout)
        await step("before")

        // Actual editor gestures, at the exact target centre in both directions.
        // The former right-to-left centre drop sent no request at all.
        let visible = service.state.tiles.filter { $0.group == .shown }.map(\.id.application)
        guard let a = visible.firstIndex(of: first), let b = visible.firstIndex(of: second) else {
            fail("both reorder fixtures must start in Visible: \(describe())")
        }
        let right = a < b ? second : first
        let left = a < b ? first : second
        await drag("centre-left", source: right, to: { center(left) }, group: .shown)
        let after = service.state.tiles.filter { $0.group == .shown }.map(\.id.application)
        guard let newRight = after.firstIndex(of: right), let newLeft = after.firstIndex(of: left), newRight < newLeft else {
            fail("the centre drop did not reverse editor order: \(describe())")
        }
        await step("reordered")

        await drag("centre-right", source: right, to: { center(left) }, group: .shown)
        let restored = service.state.tiles.filter { $0.group == .shown }.map(\.id.application)
        guard let restoredRight = restored.firstIndex(of: right), let restoredLeft = restored.firstIndex(of: left),
              restoredRight > restoredLeft else { fail("the inverse centre drop did not restore order") }
        await step("restored")

        await drag("cross-hidden", source: grouped, to: { endOfStrip(.hidden) }, group: .hidden)
        await step("grouped-editor-open")
        await drag("cross-shown", source: grouped, to: { endOfStrip(.shown) }, group: .shown)
        await step("group-restored")
        await drag("cross-hidden-again", source: grouped, to: { endOfStrip(.hidden) }, group: .hidden)
        await step("grouped-again-editor-open")

        // Closing the editor collapses the menu bar, so Hidden items go away.
        service.setEditorVisible(false)
        try? await Task.sleep(for: .seconds(2))
        await step("grouped-collapsed")

        service.toggle()
        try? await Task.sleep(for: .seconds(2))
        await step("grouped-revealed")

        try? await service.stop()
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: domain)
        print("PASS")
        fflush(stdout)
        exit(0)
    }

    nonisolated static func quietInput() -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return [CGEventSourceStateID.hidSystemState, .combinedSessionState].allSatisfy { source in
            CGEventSource.flagsState(source).intersection(modifiers).isEmpty &&
            ![CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(source, button: $0) }
        }
    }

    /// CI-only input worker. Never sends a key event or manufactures Command.
    nonisolated static func plainMouseDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        guard quietInput() else { return false }
        let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        }
        guard let move = event(.mouseMoved, start), let down = event(.leftMouseDown, start),
              let up = event(.leftMouseUp, end) else { return false }
        var drags: [CGEvent] = []
        for step in 1...24 {
            let progress = CGFloat(step) / 24
            guard let next = event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress,
                                                             y: start.y + (end.y - start.y) * progress)) else { return false }
            drags.append(next)
        }
        func post(_ event: CGEvent) {
            // Preserve genuine flags. A real modifier change aborts this test;
            // its own mouse-up still releases only the left button it pressed.
            event.flags = CGEventSource.flagsState(.combinedSessionState)
            event.post(tap: .cghidEventTap)
        }
        post(move)
        Thread.sleep(forTimeInterval: 0.12)
        guard quietInput() else { return false }
        post(down)
        defer { post(up) }
        Thread.sleep(forTimeInterval: 0.06)
        for drag in drags {
            guard CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty else { return false }
            post(drag)
            Thread.sleep(forTimeInterval: 0.018)
        }
        Thread.sleep(forTimeInterval: 0.15)
        return true
    }

    static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        fflush(stdout)
        exit(1)
    }
}
