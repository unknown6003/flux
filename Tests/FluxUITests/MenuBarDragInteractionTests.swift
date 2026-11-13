import AppKit
import Testing
import FluxCore
@testable import FluxUI

@Suite @MainActor struct MenuBarDragInteractionTests {
    @Test func perAppGroupActionsStayUsableDuringInventoryRead() {
        _ = NSApplication.shared
        let id = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.first")!, index: 0)
        var moves: [MenuBarItemMove] = []
        var state = MenuBarPageState(mode: .perApplication, isRefreshing: true,
            tiles: [.init(id: id, name: "First", group: .hidden)])
        let page = MenuBarPreferencesController(state: state, actions: .init(
            assign: { _, _ in }, beginArrange: {}, endArrange: {}, showRealIcons: {}, refresh: {},
            openAccessibilitySettings: {}, checkAccessibility: {}, reviewIdentity: { _ in }, setOption: { _ in },
            moveItem: { moves.append($0) }, editorInteractionChanged: { _ in }))
        #expect(page.performTileCommand("Move to Visible", for: id))
        #expect(moves == [.init(item: id, group: .shown, left: nil, right: nil, intent: .group)])
        state.mode = .byPosition
        page.update(state)
        #expect(!page.performTileCommand("Move to Visible", for: id))
        state.mode = .perApplication
        state.isArranging = true
        page.update(state)
        #expect(!page.performTileCommand("Move to Visible", for: id))
    }

    @Test func tileOrderRequestOpensNativeGuideWithoutPostingAMove() {
        let editor = MenuBarLayoutEditorView()
        let id = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.first")!, index: 0)
        editor.update(tiles: [.init(id: id, name: "First", group: .hidden)], alwaysHiddenEnabled: true, busy: false)
        var moves: [MenuBarItemMove] = []
        var guides = 0
        editor.onMove = { moves.append($0) }
        editor.onArrangeRequested = { guides += 1 }
        editor.request(.init(item: id, group: .hidden, left: nil, right: nil))
        #expect(moves.isEmpty)
        #expect(guides == 1)
        editor.request(.init(item: id, group: .hidden, left: nil, right: nil, intent: .group))
        #expect(moves.count == 1)
        #expect(guides == 1)
    }

    @Test func removedSourceAndLateReleaseCannotEndTheNextInteraction() throws {
        _ = NSApplication.shared
        let first = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.first")!, index: 0)
        let second = MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.second")!, index: 0)
        let editor = MenuBarLayoutEditorView()
        var changes: [Bool] = []
        editor.onInteractionChanged = { changes.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.update(tiles: [.init(id: first, name: "First"), .init(id: second, name: "Second")],
                      alwaysHiddenEnabled: true, busy: false)
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ root: NSView, _ identifier: String) -> NSView? {
            if root.accessibilityIdentifier() == identifier { return root }
            for child in root.subviews { if let result = find(child, identifier) { return result } }
            return nil
        }
        func event(_ type: NSEvent.EventType, _ tile: NSView) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let old = try #require(find(editor, "flux.menuBar.item." + first.token))
        old.mouseDown(with: try event(.leftMouseDown, old))
        #expect(changes == [true])
        editor.update(tiles: [.init(id: second, name: "Second")], alwaysHiddenEnabled: true, busy: false)
        #expect(changes == [true, false])
        let next = try #require(find(editor, "flux.menuBar.item." + second.token))
        next.mouseDown(with: try event(.leftMouseDown, next))
        #expect(changes == [true, false, true])
        old.mouseUp(with: try event(.leftMouseUp, old))
        #expect(changes == [true, false, true])
        window.contentView = nil
        #expect(changes == [true, false, true, false])
    }
}
