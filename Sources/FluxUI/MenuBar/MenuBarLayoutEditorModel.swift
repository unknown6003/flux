import CoreGraphics
import FluxCore

/// The drag and menu logic of the layout editor, without views.
/// Strips list tiles left to right, as in the real menu bar.
struct MenuBarLayoutEditorModel {
    struct Tile: Equatable {
        let id: MenuBarItemID
        let group: MenuBarGroup
        let isMovable: Bool
        var canHide = true
    }

    let tiles: [Tile]
    let alwaysHiddenEnabled: Bool

    /// Strips in screen order, top to bottom.
    var groups: [MenuBarGroup] {
        alwaysHiddenEnabled ? [.shown, .hidden, .alwaysHidden] : [.shown, .hidden]
    }

    func strip(_ group: MenuBarGroup) -> [Tile] {
        tiles.filter { displayGroup($0.group) == group }
    }

    /// With Always Hidden off, its items show in Hidden, like the saved policy.
    func displayGroup(_ group: MenuBarGroup) -> MenuBarGroup {
        group == .alwaysHidden && !alwaysHiddenEnabled ? .hidden : group
    }

    /// A drop at `index` of the target strip, counted without the dragged tile.
    /// Nil when nothing would change or the tile cannot move.
    func move(_ id: MenuBarItemID, to group: MenuBarGroup, at index: Int) -> MenuBarItemMove? {
        guard groups.contains(group), let tile = tiles.first(where: { $0.id == id }), tile.isMovable,
              group == .shown || tile.canHide else { return nil }
        let others = strip(group).filter { $0.id != id }
        let slot = min(max(index, 0), others.count)
        let left = slot > 0 ? others[slot - 1].id : nil
        let right = slot < others.count ? others[slot].id : nil
        if displayGroup(tile.group) == group {
            let current = strip(group)
            if let at = current.firstIndex(where: { $0.id == id }),
               (at > 0 ? current[at - 1].id : nil) == left,
               (at + 1 < current.count ? current[at + 1].id : nil) == right { return nil }
        }
        return MenuBarItemMove(item: id, group: group, left: left, right: right)
    }

    /// "Move to" from the context menu. The tile goes to the strip end
    /// nearest its current place, so the real drag stays short. In the menu
    /// bar, Always Hidden sits left of Hidden, and Hidden left of Visible.
    func move(_ id: MenuBarItemID, to group: MenuBarGroup) -> MenuBarItemMove? {
        guard let tile = tiles.first(where: { $0.id == id }) else { return nil }
        let from = displayGroup(tile.group)
        guard from != group else { return nil }
        let rank: [MenuBarGroup: Int] = [.alwaysHidden: 0, .hidden: 1, .shown: 2]
        let towardRight = rank[group, default: 0] > rank[from, default: 0]
        return move(id, to: group, at: towardRight ? 0 : strip(group).count)
    }

    /// Reapply a saved group without changing its peer slot. The service must
    /// still check its physical side of the chevron, even when policy matches.
    func reapply(_ id: MenuBarItemID) -> MenuBarItemMove? {
        guard let tile = tiles.first(where: { $0.id == id }), tile.isMovable else { return nil }
        let group = displayGroup(tile.group)
        guard group == .shown || tile.canHide else { return nil }
        let current = strip(group)
        guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
        return .init(item: id, group: group,
                     left: index > 0 ? current[index - 1].id : nil,
                     right: index + 1 < current.count ? current[index + 1].id : nil)
    }

    /// Move Left or Move Right by one place in the same strip.
    func nudge(_ id: MenuBarItemID, by step: Int) -> MenuBarItemMove? {
        guard let tile = tiles.first(where: { $0.id == id }) else { return nil }
        let group = displayGroup(tile.group)
        guard let index = strip(group).firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + step
        guard target >= 0, target < strip(group).count else { return nil }
        return move(id, to: group, at: target)
    }

    /// The insertion index for a drop point among tiles laid out in rows
    /// (top-left origin). Frames are in strip order and exclude the dragged tile.
    static func insertionIndex(at point: CGPoint, frames: [CGRect]) -> Int {
        for (index, frame) in frames.enumerated() {
            if point.y < frame.minY { return index }
            if point.y <= frame.maxY, point.x < frame.midX { return index }
        }
        return frames.count
    }
}
