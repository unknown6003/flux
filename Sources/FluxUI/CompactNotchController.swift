import AppKit
import FluxCore
import QuartzCore

/// Everything the compact notch shows. The parent owns the queue, the clock
/// and artwork decoding. A running timer or media time is already text or a
/// gauge inside `currentActivity`.
public struct CompactNotchState: Equatable {
    public var geometry: NotchGeometry
    public var currentActivity: ActivityItem?
    /// Shown by `.artwork` wings. Compared by identity, so the parent should
    /// pass the same `NSImage` object while the artwork has not changed.
    public var artwork: NSImage?
    /// `ActivityQueue.count`.
    public var queueCount: Int
    /// `ActivityQueue.restorableCount`.
    public var restorableCount: Int

    public init(geometry: NotchGeometry, currentActivity: ActivityItem? = nil, artwork: NSImage? = nil,
                queueCount: Int = 0, restorableCount: Int = 0) {
        self.geometry = geometry
        self.currentActivity = currentActivity
        self.artwork = artwork
        self.queueCount = max(0, queueCount)
        self.restorableCount = max(0, restorableCount)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.geometry == b.geometry && a.currentActivity == b.currentActivity && a.artwork === b.artwork
            && a.queueCount == b.queueCount && a.restorableCount == b.restorableCount
    }

    var canCycle: Bool { queueCount > 1 }
    var canDismiss: Bool { currentActivity != nil }
    var canRestore: Bool { restorableCount > 0 }
}

public enum CompactNotchAction: Equatable, Sendable {
    /// Open the expanded panel.
    case expand
    /// `ActivityQueue.cycle()`.
    case cycle
    /// `ActivityQueue.dismissCurrent()`.
    case dismissActivity
    /// `ActivityQueue.restoreLastDismissed()`.
    case restoreActivity
}

/// The closed notch: two wings beside an empty camera gap, or an idle open
/// target. The parent owns the window, hover, presentation and every service.
/// This controller has no timers, monitors or animations that repeat.
/// `update(_:)` never sends an action.
@MainActor
public final class CompactNotchController: NSViewController {
    /// Height used when `geometry.topInset` is smaller.
    public nonisolated static let minimumHeight: CGFloat = 24
    /// Camera gap on a display without a notch.
    public nonisolated static let flatGap: CGFloat = 8
    /// Accumulated scroll distance, in points, for one swipe or cycle.
    public nonisolated static let scrollThreshold: CGFloat = ScrollAccumulator.threshold

    public private(set) var state: CompactNotchState
    private let onAction: @MainActor (CompactNotchAction) -> Void

    private let shape = NotchShapeView()
    private let target = CompactNotchButton()
    private let wings = NSView()
    private let leading = CompactWingView()
    private let trailing = CompactWingView()

    public init(state: CompactNotchState, onAction: @escaping @MainActor (CompactNotchAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The exact size for the current state. The parent sizes the window to
    /// this and centers it on the screen's top edge.
    public var preferredSize: NSSize { Self.size(for: state) }

    static func size(for state: CompactNotchState) -> NSSize {
        let g = state.geometry
        let height = max(g.topInset, minimumHeight)
        let limit = min(NotchGeometry.maximumExpandedWidth, max(0, g.screenFrame.width))
        let gap = g.hasNotch ? g.cameraWidth : flatGap
        let width = state.currentActivity == nil
            ? (g.hasNotch ? g.cameraWidth : NotchGeometry.wingExtent * 2)
            : gap + NotchGeometry.wingExtent * 2
        return NSSize(width: min(width, limit), height: height)
    }

    override public func loadView() {
        let root = CompactNotchRootView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.setAccessibilityElement(false)
        shape.bottomRadius = 10
        wings.wantsLayer = true
        wings.setAccessibilityElement(false)
        for wing in [leading, trailing] { wings.addSubview(wing) }
        target.title = ""
        target.isBordered = false
        target.bezelStyle = .regularSquare
        target.setButtonType(.momentaryChange)
        target.focusRingType = .exterior
        target.target = self
        target.action = #selector(expand)
        target.onKey = { [weak self] action in self?.send(action) }
        target.onMenu = { [weak self] in self?.menu() }
        target.onScroll = { [weak self] action in self?.send(action) }
        for view in [shape, wings, target] { root.addSubview(view) }
        root.layoutChildren = { [weak self] bounds in self?.layout(in: bounds) }
        root.preferred = { [weak self] in self?.preferredSize ?? .zero }
        root.setFrameSize(preferredSize)
        preferredContentSize = preferredSize
        view = root
        apply(previous: nil)
    }

    /// Replaces the state. An equal state changes nothing. Never sends an action.
    public func update(_ newState: CompactNotchState) {
        guard newState != state else { return }
        let previous = state
        state = newState
        if isViewLoaded { apply(previous: previous) }
    }

    private func apply(previous: CompactNotchState?) {
        let size = preferredSize
        preferredContentSize = size
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true

        let item = state.currentActivity
        let changedItem = previous.map { $0.currentActivity?.id != item?.id || $0.currentActivity?.kind != item?.kind } ?? false
        if changedItem, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            wings.layer?.add(fade, forKey: "compact.change")
        }

        let tint: NSColor = item?.tint == .warning ? .systemRed : FluxUIStyle.accent
        wings.isHidden = item == nil
        leading.configure(item?.leading ?? .none, artwork: state.artwork, tint: tint, alignment: .right)
        trailing.configure(item?.trailing ?? .none, artwork: state.artwork, tint: tint, alignment: .left)

        target.setAccessibilityLabel(Self.label(for: state))
        target.toolTip = item == nil ? L("compact.open", "Open notch") : nil
        target.setAccessibilityCustomActions(customActions())
    }

    private func layout(in bounds: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        target.frame = bounds
        target.shapePath = NotchShapeView.path(in: bounds, radius: shape.bottomRadius)
        wings.frame = bounds
        let g = state.geometry
        let gap = min(g.hasNotch ? g.cameraWidth : Self.flatGap, bounds.width)
        let side = max(0, (bounds.width - gap) / 2)
        leading.frame = NSRect(x: 0, y: 0, width: side, height: bounds.height)
        trailing.frame = NSRect(x: bounds.width - side, y: 0, width: side, height: bounds.height)
        CATransaction.commit()
    }

    // MARK: Actions

    @objc private func expand() { onAction(.expand) }

    private func send(_ action: CompactNotchAction) {
        switch action {
        case .expand: onAction(.expand)
        case .cycle: if state.canCycle { onAction(.cycle) }
        case .dismissActivity: if state.canDismiss { onAction(.dismissActivity) }
        case .restoreActivity: if state.canRestore { onAction(.restoreActivity) }
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: CompactNotchAction) {
            let item = NSMenuItem(title: title, action: #selector(menuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(action)
            menu.addItem(item)
        }
        add(L("compact.open", "Open notch"), .expand)
        if state.canCycle { add(L("compact.next", "Next Activity"), .cycle) }
        if state.canDismiss { add(L("compact.dismiss", "Dismiss Activity"), .dismissActivity) }
        if state.canRestore { add(L("compact.restore", "Restore Activity"), .restoreActivity) }
        return menu
    }

    @objc private func menuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuAction else { return }
        send(box.action)
    }

    private func customActions() -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        func add(_ name: String, _ selector: Selector) {
            actions.append(NSAccessibilityCustomAction(name: name, target: self, selector: selector))
        }
        if state.canCycle { add(L("compact.next", "Next Activity"), #selector(axCycle)) }
        if state.canDismiss { add(L("compact.dismiss", "Dismiss Activity"), #selector(axDismiss)) }
        if state.canRestore { add(L("compact.restore", "Restore Activity"), #selector(axRestore)) }
        return actions
    }

    @objc private func axCycle() -> Bool { send(.cycle); return true }
    @objc private func axDismiss() -> Bool { send(.dismissActivity); return true }
    @objc private func axRestore() -> Bool { send(.restoreActivity); return true }

    // MARK: VoiceOver text

    static func label(for state: CompactNotchState) -> String {
        guard let item = state.currentActivity else { return L("compact.open", "Open notch") }
        var parts = [kindName(item.kind)]
        if item.tint == .warning { parts.append(L("compact.warning", "Warning")) }
        for wing in [item.leading, item.trailing] {
            if let text = wingText(wing) { parts.append(text) }
        }
        if state.queueCount > 1 {
            parts.append(String(format: L("compact.count", "%d activities"), state.queueCount))
        }
        return parts.joined(separator: ", ")
    }

    static func kindName(_ kind: ActivityKind) -> String {
        switch kind {
        case .battery: L("activity.battery", "Battery")
        case .bluetoothDevice: L("activity.bluetooth", "Bluetooth device")
        case .timer: L("activity.timer", "Timer")
        case .shelfDrop: L("activity.shelf", "File Shelf")
        case .menuBarOverflow: L("activity.menuBar", "Hidden menu bar icons")
        case .nowPlaying: L("activity.nowPlaying", "Now Playing")
        case .calendarEvent: L("activity.calendar", "Calendar event")
        case .soundHUD: L("activity.sound", "Volume")
        }
    }

    static func wingText(_ wing: ActivityWing) -> String? {
        switch wing {
        case .none, .symbol: return nil
        case .artwork: return L("compact.artwork", "Artwork")
        case .text(let text), .symbolText(_, let text): return text.isEmpty ? nil : text
        case .gauge(let value, _), .soundGauge(let value, _):
            return String(format: L("compact.percent", "%d percent"), Int((compactUnit(value) * 100).rounded()))
        }
    }
}

private final class MenuAction: NSObject {
    let action: CompactNotchAction
    init(_ action: CompactNotchAction) { self.action = action }
}

func compactUnit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }

/// Flipped root with an exact intrinsic size. It hands layout to the controller.
@MainActor
private final class CompactNotchRootView: NSView {
    var layoutChildren: ((NSRect) -> Void)?
    var preferred: (() -> NSSize)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { preferred?() ?? .zero }
    override func layout() {
        super.layout()
        layoutChildren?(bounds)
    }
}

/// The open target. Click or Space opens. Arrow keys, scroll and swipe map to
/// queue actions. The controller drops actions that are not possible.
@MainActor
final class CompactNotchButton: NSButton {
    var onKey: ((CompactNotchAction) -> Void)?
    var onScroll: ((CompactNotchAction) -> Void)?
    var onMenu: (() -> NSMenu?)?
    var shapePath: CGPath? { didSet { noteFocusRingMaskChanged() } }
    private var scroll = ScrollAccumulator()

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard let shapePath, let context = NSGraphicsContext.current?.cgContext else {
            bounds.fill()
            return
        }
        context.addPath(shapePath)
        context.fillPath()
    }
    override func draw(_ dirtyRect: NSRect) {}

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: onKey?(.dismissActivity)
        case .rightArrow?: onKey?(.restoreActivity)
        case .upArrow?, .downArrow?: onKey?(.cycle)
        case .carriageReturn?, .enter?: onKey?(.expand)
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = onMenu?() else { return false }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.maxY), in: self)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        if let action = scroll.feed(event) { onScroll?(action) }
    }

    /// Three-finger swipe, when the user's trackpad sends it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { onScroll?(.dismissActivity) }
        else if event.deltaX < 0 { onScroll?(.restoreActivity) }
        else if event.deltaY != 0 { onScroll?(.cycle) }
    }
}

/// Turns scroll events into at most one action per gesture. A trackpad
/// gesture fires once, then waits for `.ended` or `.cancelled`. Momentum is
/// ignored. A mouse wheel has no phase, so the sum resets after each action.
/// No timer.
@MainActor
struct ScrollAccumulator {
    nonisolated static let threshold: CGFloat = 30
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var fired = false

    mutating func feed(_ event: NSEvent) -> CompactNotchAction? {
        if !event.momentumPhase.isEmpty { return nil }
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) { reset() }
        if phase.contains(.ended) || phase.contains(.cancelled) { reset(); return nil }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // Finger direction: natural scrolling already follows the fingers.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        return feed(dx: event.scrollingDeltaX * scale * sign, dy: event.scrollingDeltaY * scale, phased: !phase.isEmpty)
    }

    /// `dx` is finger motion: negative is left.
    mutating func feed(dx deltaX: CGFloat, dy deltaY: CGFloat, phased: Bool) -> CompactNotchAction? {
        guard deltaX.isFinite, deltaY.isFinite, !fired else { return nil }
        dx += deltaX
        dy += deltaY
        let threshold = Self.threshold
        var action: CompactNotchAction?
        if abs(dx) >= threshold, abs(dx) > abs(dy) { action = dx < 0 ? .dismissActivity : .restoreActivity }
        else if abs(dy) >= threshold, abs(dy) >= abs(dx) { action = .cycle }
        guard let action else { return nil }
        if phased { fired = true } else { reset() }
        return action
    }

    mutating func reset() { dx = 0; dy = 0; fired = false }
}

/// One wing: a symbol, text, symbol and text, artwork, a ring gauge or a
/// level bar. All drawing is static. Content is clipped to the wing.
@MainActor
final class CompactWingView: NSView {
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private var wing: ActivityWing = .none
    private var alignment: NSTextAlignment = .center

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.masksToBounds = true
        image.setAccessibilityElement(false)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        for shapeLayer in [track, ring] {
            shapeLayer.fillColor = nil
            shapeLayer.lineCap = .round
            layer?.addSublayer(shapeLayer)
        }
        addSubview(image)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ wing: ActivityWing, artwork: NSImage?, tint: NSColor, alignment: NSTextAlignment) {
        self.wing = wing
        self.alignment = alignment
        label.textColor = tint
        label.alignment = alignment
        image.contentTintColor = tint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        ring.strokeColor = tint.cgColor
        CATransaction.commit()
        switch wing {
        case .none:
            setImage(nil)
            label.stringValue = ""
        case .symbol(let name):
            setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil))
            label.stringValue = ""
        case .text(let text):
            setImage(nil)
            label.stringValue = text
        case .symbolText(let name, let text):
            setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil))
            label.stringValue = text
        case .artwork:
            if let artwork { setImage(artwork) } else { setImage(NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)) }
            image.contentTintColor = artwork == nil ? .secondaryLabelColor : nil
            label.stringValue = ""
        case .gauge(_, let name), .soundGauge(_, let name):
            setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil))
            label.stringValue = ""
        }
        needsLayout = true
    }

    /// Keeps the same image object, so equal artwork is not set again.
    private func setImage(_ newImage: NSImage?) {
        if image.image !== newImage { image.image = newImage }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inset: CGFloat = 6
        let content = bounds.insetBy(dx: inset, dy: 4)
        let side = max(0, min(content.height, 22))
        let midY = bounds.midY
        image.isHidden = image.image == nil
        label.isHidden = label.stringValue.isEmpty
        track.isHidden = true
        ring.isHidden = true
        image.layer?.cornerRadius = 0
        image.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        guard content.width > 0, content.height > 0 else {
            image.frame = .zero; label.frame = .zero
            return
        }

        func square(_ size: CGFloat) -> NSRect {
            let s = min(size, content.width)
            let x = alignment == .right ? content.maxX - s : alignment == .left ? content.minX : content.midX - s / 2
            return NSRect(x: x, y: midY - s / 2, width: s, height: s)
        }

        switch wing {
        case .none:
            image.frame = .zero; label.frame = .zero
        case .symbol:
            image.frame = square(min(side, 18))
        case .text:
            label.frame = NSRect(x: content.minX, y: midY - 8, width: content.width, height: 16)
        case .symbolText:
            image.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            let icon = min(12, content.width)
            let textWidth = max(0, content.width - icon - 2)
            image.frame = NSRect(x: content.minX, y: midY - icon / 2, width: icon, height: icon)
            label.frame = NSRect(x: content.minX + icon + 2, y: midY - 8, width: textWidth, height: 16)
            label.alignment = .left
        case .artwork:
            image.frame = square(side)
            image.layer?.cornerRadius = 5
        case .gauge(let value, _):
            let frame = square(side)
            image.symbolConfiguration = .init(pointSize: 8, weight: .bold)
            image.frame = frame.insetBy(dx: frame.width * 0.28, dy: frame.height * 0.28)
            let path = CGPath(ellipseIn: frame.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            for shapeLayer in [track, ring] {
                shapeLayer.isHidden = false
                shapeLayer.frame = bounds
                shapeLayer.path = path
                shapeLayer.lineWidth = 2.5
            }
            ring.strokeEnd = compactUnit(value)
        case .soundGauge(let value, _):
            image.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            let icon = min(12, content.width)
            image.frame = NSRect(x: content.minX, y: midY - icon / 2, width: icon, height: icon)
            let barX = content.minX + icon + 3
            let barWidth = max(0, content.maxX - barX)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: barX + 2, y: midY))
            path.addLine(to: CGPoint(x: max(barX + 2, barX + barWidth - 2), y: midY))
            for shapeLayer in [track, ring] {
                shapeLayer.isHidden = barWidth < 4
                shapeLayer.frame = bounds
                shapeLayer.path = path
                shapeLayer.lineWidth = 4
            }
            ring.strokeEnd = compactUnit(value)
        }
    }
}
