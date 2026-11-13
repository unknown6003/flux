import AppKit
import FluxCore

/// Three strips of real menu bar items: Visible, Hidden and Always Hidden.
/// Tiles request group changes or a named slot in the live menu bar.
@MainActor
final class MenuBarLayoutEditorView: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("com.flux.menubar.layout-item")

    var onMove: ((MenuBarItemMove) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    private var interaction: UUID?
    private(set) var model = MenuBarLayoutEditorModel(tiles: [], alwaysHiddenEnabled: true)
    private var tiles: [MenuBarItemID: MenuBarLayoutTile] = [:]
    private var strips: [MenuBarGroup: MenuBarStripView] = [:]
    private let stack = FluxUIStyle.vstack([], spacing: 14)
    fileprivate(set) var isBusy = false

    init() {
        super.init(frame: .zero)
        for group in MenuBarGroup.allCases {
            let strip = MenuBarStripView(group: group, editor: self)
            strips[group] = strip
            stack.addArrangedSubview(strip)
        }
        FluxUIStyle.pin(stack, in: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("menuBar.layout.title", "Menu Bar Layout"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The first tile that can take keyboard focus.
    var firstTile: NSView? {
        model.groups.lazy.compactMap { self.strips[$0]?.firstTile }.first
    }

    func update(tiles newTiles: [MenuBarLayoutTile], alwaysHiddenEnabled: Bool, busy: Bool) {
        isBusy = busy
        tiles = Dictionary(newTiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model = MenuBarLayoutEditorModel(tiles: newTiles.map {
            .init(id: $0.id, group: $0.group, isMovable: $0.isMovable, canHide: $0.canHide)
        }, alwaysHiddenEnabled: alwaysHiddenEnabled)
        for group in MenuBarGroup.allCases {
            guard let strip = strips[group] else { continue }
            strip.isHidden = !model.groups.contains(group)
            strip.setTiles(model.strip(group).compactMap { tiles[$0.id] }, busy: busy)
        }
    }

    func tile(_ id: MenuBarItemID) -> MenuBarLayoutTile? { tiles[id] }

    fileprivate func beginInteraction() -> UUID? {
        guard !isBusy, interaction == nil else { return nil }
        let token = UUID()
        interaction = token
        onInteractionChanged?(true)
        return token
    }

    fileprivate func endInteraction(_ token: UUID) {
        guard interaction == token else { return }
        interaction = nil
        onInteractionChanged?(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let interaction { endInteraction(interaction) }
        super.viewWillMove(toWindow: newWindow)
    }

    func request(_ move: MenuBarItemMove?) {
        guard !isBusy, let move else { return }
        onMove?(move)
    }

    /// The checked group can be reapplied to repair a saved but unplaced icon.
    func menu(for id: MenuBarItemID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let tile = tiles[id], tile.isMovable else {
            let item = NSMenuItem(title: L("menuBar.layout.locked", "macOS keeps this icon in place"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        let current = model.displayGroup(tile.group)
        for group in model.groups where group == .shown || tile.canHide {
            let title = String(format: L("menuBar.layout.moveTo", "Move to %@"), group.title)
            let action = MenuAction(title: title, enabled: !isBusy) { [weak self] in
                guard let self else { return }
                self.request(group == current ? self.model.reapply(id) : self.model.move(id, to: group))
            }
            action.state = group == current ? .on : .off
            menu.addItem(action)
        }
        menu.addItem(.separator())
        for (step, title) in [(-1, "Move Left"), (1, "Move Right")] {
            let move = model.nudge(id, by: step)
            menu.addItem(MenuAction(title: title, enabled: !isBusy && move != nil) { [weak self] in self?.request(move) })
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure.
@MainActor
private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(title: String, enabled: Bool, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

/// One strip: a title, one help line, and a drop area of tiles.
@MainActor
private final class MenuBarStripView: NSView {
    let group: MenuBarGroup
    private let flow: MenuBarFlowView

    init(group: MenuBarGroup, editor: MenuBarLayoutEditorView) {
        self.group = group
        flow = MenuBarFlowView(group: group, editor: editor)
        super.init(frame: .zero)
        let title = FluxUIStyle.label(group.title, style: .headline, wraps: false)
        let help = FluxUIStyle.label(group.stripHelp, style: .callout, secondary: true)
        let stack = FluxUIStyle.vstack([title, help, flow], spacing: 4)
        stack.setCustomSpacing(8, after: help)
        FluxUIStyle.pin(stack, in: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(group.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var firstTile: NSView? { flow.tileViews.first(where: { $0.acceptsFirstResponder }) }

    func setTiles(_ tiles: [MenuBarLayoutTile], busy: Bool) { flow.setTiles(tiles, busy: busy) }
}

/// Lays tiles out left to right in rows, and takes drops.
@MainActor
private final class MenuBarFlowView: NSView {
    static let padding: CGFloat = 8
    static let gap: CGFloat = 6
    static let tileHeight: CGFloat = 30

    let group: MenuBarGroup
    private weak var editor: MenuBarLayoutEditorView?
    private(set) var tileViews: [MenuBarTileView] = []
    private let empty = FluxUIStyle.label(L("menuBar.layout.empty", "Drag icons here"), style: .callout, secondary: true, wraps: false)
    private var marker: CGRect? { didSet { needsDisplay = true } }
    private var targeted = false { didSet { needsDisplay = true } }
    private var laidOutHeight: CGFloat = 0

    init(group: MenuBarGroup, editor: MenuBarLayoutEditorView) {
        self.group = group
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        addSubview(empty)
        registerForDraggedTypes([MenuBarLayoutEditorView.pasteboardType])
        setAccessibilityIdentifier("flux.menuBar.drop." + group.rawValue)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    func setTiles(_ tiles: [MenuBarLayoutTile], busy: Bool) {
        var reusable = Dictionary(tileViews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [MenuBarTileView] = []
        for tile in tiles {
            let view = reusable.removeValue(forKey: tile.id) ?? MenuBarTileView(id: tile.id, flow: self)
            view.apply(tile, busy: busy)
            if view.superview !== self { addSubview(view) }
            next.append(view)
        }
        for view in reusable.values { view.removeFromSuperview() }
        tileViews = next
        empty.isHidden = !tiles.isEmpty
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var editorView: MenuBarLayoutEditorView? { editor }

    // MARK: Layout

    /// Frames for `widths` in rows inside `width`. Shared with drop math.
    static func frames(widths: [CGFloat], width: CGFloat) -> [CGRect] {
        var x = padding, y = padding
        var frames: [CGRect] = []
        for tileWidth in widths {
            if x > padding, x + tileWidth > width - padding {
                x = padding
                y += tileHeight + gap
            }
            frames.append(CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
            x += tileWidth + gap
        }
        return frames
    }

    private func height(for width: CGFloat) -> CGFloat {
        guard let last = Self.frames(widths: tileViews.map(\.preferredWidth), width: width).last else {
            return Self.tileHeight + Self.padding * 2
        }
        return last.maxY + Self.padding
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: max(bounds.width, 200)))
    }

    override func layout() {
        super.layout()
        let frames = Self.frames(widths: tileViews.map(\.preferredWidth), width: bounds.width)
        for (view, frame) in zip(tileViews, frames) { view.frame = frame }
        let size = empty.fittingSize
        empty.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
        let height = height(for: bounds.width)
        if abs(height - laidOutHeight) > 0.5 {
            laidOutHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (targeted ? FluxUIStyle.accent.withAlphaComponent(0.10) : NSColor.quaternarySystemFill).setFill()
        shape.fill()
        (targeted ? FluxUIStyle.accent : NSColor.separatorColor).setStroke()
        shape.lineWidth = targeted ? 1.5 : 0.5
        shape.stroke()
        if let marker {
            FluxUIStyle.accent.setFill()
            NSBezierPath(roundedRect: marker, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    // MARK: Drops

    private func draggedID(_ info: NSDraggingInfo) -> MenuBarItemID? {
        guard let editor, !editor.isBusy, let source = info.draggingSource as? MenuBarTileView,
              source.window === window,
              let token = info.draggingPasteboard.string(forType: MenuBarLayoutEditorView.pasteboardType),
              let id = MenuBarItemID(token: token), id == source.id else { return nil }
        return id
    }

    /// The insertion index among the other tiles, and where to draw the marker.
    private func drop(at point: CGPoint, excluding id: MenuBarItemID) -> (index: Int, marker: CGRect) {
        let others = tileViews.filter { $0.id != id }
        let frames = others.map(\.frame)
        let sourceIndex = tileViews.firstIndex { $0.id == id }
        let index = MenuBarLayoutEditorModel.insertionIndex(at: point, frames: frames, sourceIndex: sourceIndex)
        let x: CGFloat, y: CGFloat
        if index < frames.count { x = frames[index].minX - Self.gap / 2; y = frames[index].minY }
        else if let last = frames.last { x = last.maxX + Self.gap / 2; y = last.minY }
        else { x = Self.padding; y = Self.padding }
        return (index, CGRect(x: x - 1.5, y: y, width: 3, height: Self.tileHeight))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(sender) else { targeted = false; marker = nil; return [] }
        targeted = true
        marker = drop(at: convert(sender.draggingLocation, from: nil), excluding: id).marker
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false; marker = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { targeted = false; marker = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggedID(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false; marker = nil
        guard let id = draggedID(sender), let editor else { return false }
        let index = drop(at: convert(sender.draggingLocation, from: nil), excluding: id).index
        editor.request(editor.model.move(id, to: group, at: index))
        return true
    }
}

/// One item image. Drag to move. Right-click, Return or Space for the menu.
@MainActor
private final class MenuBarTileView: NSView, NSDraggingSource {
    let id: MenuBarItemID
    private weak var flow: MenuBarFlowView?
    private var image: NSImage?
    private var name = ""
    private var movable = false
    private var busy = false
    private var down: NSEvent?
    private var pressToken: UUID?
    private var sessions: [ObjectIdentifier: UUID] = [:]

    init(id: MenuBarItemID, flow: MenuBarFlowView) {
        self.id = id
        self.flow = flow
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("flux.menuBar.item." + id.token)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Real images keep their width. App icons get a square.
    var preferredWidth: CGFloat {
        guard let image, image.size.height > 0 else { return 30 }
        let width = image.size.width * min(1, 22 / image.size.height)
        return min(max(width + 8, 30), 140)
    }

    func apply(_ tile: MenuBarLayoutTile, busy: Bool) {
        let changed = image !== tile.image || name != tile.name || movable != tile.isMovable || self.busy != busy
        image = tile.image ?? Self.tinted("app.dashed")
        name = tile.name
        movable = tile.isMovable
        self.busy = busy
        toolTip = movable ? String(format: L("menuBar.tile.orderHelp", "%@. Drag to change its order or group."), name)
            : String(format: L("menuBar.tile.locked", "%@. macOS keeps this icon in place."), name)
        setAccessibilityLabel(String(format: L("menuBar.tile.ax", "%@, %@"), name, tile.group.title))
        setAccessibilityHelp(toolTip)
        if changed { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func mouseDown(with event: NSEvent) {
        guard movable, !busy, let token = flow?.editorView?.beginInteraction() else { return }
        pressToken = token
        down = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, let token = pressToken, movable, !busy else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        down = nil
        pressToken = nil
        let item = NSPasteboardItem()
        item.setString(id.token, forType: MenuBarLayoutEditorView.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [dragging], event: start, source: self)
        sessions[ObjectIdentifier(session)] = token
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        down = nil
        if let token = pressToken {
            pressToken = nil
            flow?.editorView?.endInteraction(token)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if let token = pressToken {
                pressToken = nil
                down = nil
                flow?.editorView?.endInteraction(token)
            }
            for token in sessions.values { flow?.editorView?.endInteraction(token) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? { flow?.editorView?.menu(for: id) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: showMenu()
        case 123: window?.selectPreviousKeyView(nil)
        case 124: window?.selectNextKeyView(nil)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { showMenu(); return true }
    override func accessibilityPerformShowMenu() -> Bool { showMenu(); return true }

    private func showMenu() {
        guard let menu = flow?.editorView?.menu(for: id) else { return }
        window?.makeFirstResponder(self)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let token = sessions.removeValue(forKey: ObjectIdentifier(session)) {
            flow?.editorView?.endInteraction(token)
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    override func resetCursorRects() {
        if movable, !busy { addCursorRect(bounds, cursor: .openHand) }
    }

    private func snapshot() -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return image ?? NSImage() }
        cacheDisplay(in: bounds, to: bitmap)
        let result = NSImage(size: bounds.size)
        result.addRepresentation(bitmap)
        return result
    }

    /// Real captures carry the menu bar's own background, so the tile adds
    /// none. Locked items get a small lock in the corner.
    override func draw(_ dirtyRect: NSRect) {
        if let image {
            let size = image.size.height > 0 ? image.size : NSSize(width: 18, height: 18)
            let scale = min(1, 22 / max(size.height, 1), (bounds.width - 6) / max(size.width, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            let rect = NSRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: busy ? 0.45 : 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        if !movable {
            Self.tinted("lock.fill")?.draw(in: NSRect(x: bounds.maxX - 9, y: bounds.maxY - 10, width: 8, height: 9),
                                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    static func tinted(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
    }
}
