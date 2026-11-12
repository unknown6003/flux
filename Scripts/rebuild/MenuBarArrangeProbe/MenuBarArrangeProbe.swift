import AppKit
import FluxApplication
import FluxCore
import FluxPlatform
import FluxUI

/// CI only. Drives the Menu Bar layout editor against the real menu bar:
/// the editor's right-click commands go through the same page actions,
/// service, planner and Cmd-drag that a user's drop uses.
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
        let actions = MenuBarPageActions(assign: { service.assign($0, to: $1) }, beginArrange: {}, endArrange: {},
            showRealIcons: {}, refresh: { service.refresh() }, openAccessibilitySettings: {}, checkAccessibility: {},
            reviewIdentity: { _ in }, setOption: { _ in }, moveItem: { service.moveItem($0) })
        let page = MenuBarPreferencesController(state: service.state, actions: actions)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 680, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = page
        // The page is a scroll view with no fitting size; keep the window readable.
        window.setContentSize(NSSize(width: 680, height: 700))
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 40))
        window.orderFrontRegardless()
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
        func command(_ title: String, _ application: ApplicationID) async {
            guard let id = tile(application)?.id else { fail("\(application.rawValue) is not in the editor: \(describe())") }
            guard page.performTileCommand(title, for: id) else { fail("\(title) is not available for \(application.rawValue): \(describe())") }
            await wait(40, title) {
                if case .moving = service.state.moveStatus { return false }
                return service.state.moveStatus != nil && !service.state.isRefreshing
            }
            guard case .moved = service.state.moveStatus else { fail("\(title) failed: \(describe())") }
            guard MenuBarItemDrag.inputIsQuiet() else { fail("\(title) left synthetic input held") }
        }

        await wait(30, "inventory") {
            !service.state.isRefreshing && [first, second, grouped].allSatisfy { tile($0) != nil }
                && service.state.mode != .paused
        }
        print("READY \(describe())")
        fflush(stdout)
        await step("before")

        // Reorder: the right fixture moves left of the other, within Visible.
        let visible = service.state.tiles.filter { $0.group == .shown }.map(\.id.application)
        guard let a = visible.firstIndex(of: first), let b = visible.firstIndex(of: second) else {
            fail("both reorder fixtures must start in Visible: \(describe())")
        }
        let right = a < b ? second : first
        let left = a < b ? first : second
        let moves = abs(a - b)
        for _ in 0..<moves { await command("Move Left", right) }
        let after = service.state.tiles.filter { $0.group == .shown }.map(\.id.application)
        guard let newRight = after.firstIndex(of: right), let newLeft = after.firstIndex(of: left), newRight < newLeft else {
            fail("the editor order did not change: \(describe())")
        }
        await step("reordered")

        // Group change: one fixture moves from Visible to Hidden.
        await command("Move to Hidden", grouped)
        guard tile(grouped)?.group == .hidden else { fail("the group did not change: \(describe())") }
        await step("grouped-editor-open")

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

    static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        fflush(stdout)
        exit(1)
    }
}
