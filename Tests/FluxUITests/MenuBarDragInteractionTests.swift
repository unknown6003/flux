import AppKit
import Testing
import FluxCore
@testable import FluxUI

@Suite @MainActor struct MenuBarDragInteractionTests {
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
