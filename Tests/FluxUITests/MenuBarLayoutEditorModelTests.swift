import AppKit
import Testing
import FluxCore
@testable import FluxUI

private func id(_ name: String, _ index: Int = 0) -> MenuBarItemID {
    MenuBarItemID(application: ApplicationID(rawValue: "org.fluxfixture.\(name)")!, index: index)
}

/// Visible: a b c. Hidden: d e. Always Hidden: f. System item s is locked.
private func model(alwaysHidden: Bool = true) -> MenuBarLayoutEditorModel {
    let tiles: [MenuBarLayoutEditorModel.Tile] = [
        .init(id: id("f"), group: .alwaysHidden, isMovable: true),
        .init(id: id("d"), group: .hidden, isMovable: true),
        .init(id: id("e"), group: .hidden, isMovable: true),
        .init(id: id("a"), group: .shown, isMovable: true),
        .init(id: id("b"), group: .shown, isMovable: true),
        .init(id: id("c"), group: .shown, isMovable: true),
        .init(id: id("s"), group: .shown, isMovable: false),
    ]
    return MenuBarLayoutEditorModel(tiles: tiles, alwaysHiddenEnabled: alwaysHidden)
}

@Suite struct MenuBarLayoutEditorModelTests {
    @Test func dropWithinAStripNamesTheNewNeighbours() {
        let editor = model()
        // Drop c before a: index 0 among a, b, s.
        #expect(editor.move(id("c"), to: .shown, at: 0) == .init(item: id("c"), group: .shown, left: nil, right: id("a")))
        // Drop a after b: index 2 among b, c, s.
        #expect(editor.move(id("a"), to: .shown, at: 2) == .init(item: id("a"), group: .shown, left: id("c"), right: id("s")))
        // Dropping a tile back where it was does nothing.
        #expect(editor.move(id("b"), to: .shown, at: 1) == nil)
        #expect(editor.move(id("a"), to: .shown, at: 0) == nil)
    }

    @Test func dropIntoAnotherStripChangesTheGroup() {
        let editor = model()
        #expect(editor.move(id("a"), to: .hidden, at: 1) == .init(item: id("a"), group: .hidden, left: id("d"), right: id("e")))
        #expect(editor.move(id("e"), to: .alwaysHidden, at: 5) == .init(item: id("e"), group: .alwaysHidden, left: id("f"), right: nil))
        #expect(editor.move(id("s"), to: .hidden, at: 0) == nil)
    }

    @Test func menuMovesToTheNearEndOfTheTargetStrip() {
        let editor = model()
        // Visible to Hidden: the right end of Hidden, next to Visible.
        #expect(editor.move(id("b"), to: .hidden) == .init(item: id("b"), group: .hidden, left: id("e"), right: nil))
        // Hidden to Visible: the left end of Visible.
        #expect(editor.move(id("d"), to: .shown) == .init(item: id("d"), group: .shown, left: nil, right: id("a")))
        // Always Hidden to Hidden: the left end of Hidden.
        #expect(editor.move(id("f"), to: .hidden) == .init(item: id("f"), group: .hidden, left: nil, right: id("d")))
        #expect(editor.move(id("a"), to: .shown) == nil)
    }

    @Test func anItemMacOSAlwaysDrawsMovesOnlyWithinVisible() {
        let tiles: [MenuBarLayoutEditorModel.Tile] = [
            .init(id: id("d"), group: .hidden, isMovable: true),
            .init(id: id("a"), group: .shown, isMovable: true),
            .init(id: id("k"), group: .shown, isMovable: true, canHide: false),
        ]
        let editor = MenuBarLayoutEditorModel(tiles: tiles, alwaysHiddenEnabled: true)
        #expect(editor.move(id("k"), to: .shown, at: 0) == .init(item: id("k"), group: .shown, left: nil, right: id("a")))
        #expect(editor.move(id("k"), to: .hidden, at: 0) == nil)
        #expect(editor.move(id("k"), to: .alwaysHidden) == nil)
    }

    @Test func nudgeMovesOnePlaceAndStopsAtTheEnds() {
        let editor = model()
        #expect(editor.nudge(id("a"), by: 1) == .init(item: id("a"), group: .shown, left: id("b"), right: id("c")))
        #expect(editor.nudge(id("c"), by: -1) == .init(item: id("c"), group: .shown, left: id("a"), right: id("b")))
        #expect(editor.nudge(id("a"), by: -1) == nil)
        #expect(editor.nudge(id("e"), by: 1) == nil)
    }

    @Test func alwaysHiddenOffFoldsItsItemsIntoHidden() {
        let editor = model(alwaysHidden: false)
        #expect(editor.groups == [.shown, .hidden])
        #expect(editor.strip(.hidden).map(\.id) == [id("f"), id("d"), id("e")])
        #expect(editor.move(id("a"), to: .alwaysHidden, at: 0) == nil)
        #expect(editor.move(id("f"), to: .hidden) == nil)
    }

    @Test func insertionIndexFollowsRowsLeftToRight() {
        // Two rows: 0 1 2 / 3 4
        let frames = [CGRect(x: 8, y: 8, width: 30, height: 30), CGRect(x: 44, y: 8, width: 30, height: 30),
                      CGRect(x: 80, y: 8, width: 30, height: 30),
                      CGRect(x: 8, y: 44, width: 30, height: 30), CGRect(x: 44, y: 44, width: 30, height: 30)]
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 10, y: 20), frames: frames) == 0)
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 70, y: 20), frames: frames) == 2)
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 200, y: 20), frames: frames) == 3)
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 50, y: 60), frames: frames) == 4)
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 200, y: 60), frames: frames) == 5)
        #expect(MenuBarLayoutEditorModel.insertionIndex(at: CGPoint(x: 5, y: 5), frames: []) == 0)
    }

    @Test @MainActor func editorSendsTheMoveFromItsMenuAndRefusesWhileBusy() throws {
        _ = NSApplication.shared
        let editor = MenuBarLayoutEditorView()
        var moves: [MenuBarItemMove] = []
        editor.onMove = { moves.append($0) }
        let tiles = [MenuBarLayoutTile(id: id("a"), name: "A"), MenuBarLayoutTile(id: id("b"), name: "B"),
                     MenuBarLayoutTile(id: id("d"), name: "D", group: .hidden)]
        editor.update(tiles: tiles, alwaysHiddenEnabled: true, busy: false)
        let menu = editor.menu(for: id("a"))
        #expect(menu.items.map(\.title) == ["Move to Hidden", "Move to Always Hidden", "", "Move Left", "Move Right"])
        #expect(menu.items[3].isEnabled == false)
        menu.performActionForItem(at: 0)
        #expect(moves == [.init(item: id("a"), group: .hidden, left: id("d"), right: nil)])
        editor.update(tiles: tiles, alwaysHiddenEnabled: true, busy: true)
        let busy = editor.menu(for: id("a"))
        #expect(busy.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        busy.performActionForItem(at: 4)
        #expect(moves.count == 1)
    }
}
