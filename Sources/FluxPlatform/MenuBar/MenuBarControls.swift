import AppKit
import FluxCore

/// Flux-owned controls only. The owner selects a hiding capability after its
/// backend passes acceptance. This class never moves another app's icon or
/// writes its allowance. An unavailable backend keeps the boundaries small.
@MainActor public final class MenuBarControls: NSObject {
    public var onToggle: (@MainActor (_ showAll: Bool) -> Void)?
    public var onFinishArrange: (@MainActor () -> Void)?
    public var contextMenu: NSMenu?
    public private(set) var isStarted = false
    public private(set) var isArranging = false
    private var capability: MenuBarCapability = .unavailable
    private var reveal: MenuBarReveal = .all
    private var alwaysEnabled = true
    private var style: MenuBarIcon = .chevron
    private var toggle: NSStatusItem?
    private var hidden: NSStatusItem?
    private var always: NSStatusItem?
    private var displayObservation: NotificationObservation?

    public override init() { super.init() }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Creation order is right to left. Reuse Flux's existing position IDs.
        toggle = make("flux.chevron")
        hidden = make("flux.divider.hidden")
        always = make("flux.divider.alwaysHidden")
        for item in [toggle, hidden, always] {
            item?.button?.target = self
            item?.button?.action = #selector(clicked(_:))
            item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        displayObservation = NotificationObservation(center: .default,
            name: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
                Task { @MainActor [weak self] in self?.render() }
            }
        render()
    }

    public func stop() {
        guard isStarted else { return }
        // Shrink owned spacers before removing them. No external item is moved.
        capability = .unavailable; isArranging = false; reveal = .all
        render()
        displayObservation = nil
        for item in [toggle, hidden, always].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        toggle = nil; hidden = nil; always = nil
        contextMenu = nil; isStarted = false
    }

    public func configure(capability: MenuBarCapability, reveal: MenuBarReveal,
                          alwaysHiddenEnabled: Bool, style: MenuBarIcon) {
        self.capability = capability; self.reveal = reveal
        alwaysEnabled = alwaysHiddenEnabled; self.style = style
        render()
    }

    public func setArranging(_ arranging: Bool) {
        guard arranging != isArranging else { return }
        isArranging = arranging
        render()
    }

    /// AppKit frames of Flux's own controls. These are not an inventory or
    /// evidence of another app's physical visibility.
    public var hiddenBoundary: CGRect? { hidden?.button?.window?.frame }
    public var alwaysHiddenBoundary: CGRect? { always?.button?.window?.frame }

    private func make(_ name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let suffix = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? ".v27" : ""
        item.autosaveName = name + suffix
        item.behavior = []
        item.isVisible = true
        return item
    }

    private func render() {
        guard isStarted else { return }
        let symbol: String
        if isArranging { symbol = "checkmark" }
        else {
            switch style {
            case .chevron: symbol = reveal == .collapsed ? "chevron.left" : "chevron.right"
            case .dot: symbol = "circle.fill"
            case .line: symbol = "minus"
            }
        }
        toggle?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flux")
        toggle?.button?.image?.isTemplate = true
        let hint = isArranging ? "Finish arranging menu bar icons" : "Show or hide menu bar icons"
        toggle?.button?.toolTip = hint
        toggle?.button?.setAccessibilityLabel(hint)
        let lengths = Self.lengths(capability: capability, reveal: reveal, alwaysEnabled: alwaysEnabled,
            arranging: isArranging, screenWidths: NSScreen.screens.map(\.frame.width),
            modern: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        boundary(hidden, title: "Hidden", length: lengths.hidden)
        boundary(always, title: "Always", length: lengths.always)
        always?.isVisible = alwaysEnabled && (isArranging || capability == .byPosition)
        hidden?.isVisible = isArranging || capability == .byPosition
    }

    private func boundary(_ item: NSStatusItem?, title: String, length: CGFloat) {
        guard let item, let button = item.button else { return }
        button.title = isArranging ? title : "|"
        button.image = nil
        button.toolTip = "Hold Command and drag icons to the left of this marker for " + title
        button.setAccessibilityLabel(title + " boundary")
        if !isArranging, length > 24 { button.title = "" }
        item.length = length
    }

    static func lengths(capability: MenuBarCapability, reveal: MenuBarReveal, alwaysEnabled: Bool,
                        arranging: Bool, screenWidths: [CGFloat], modern: Bool) -> (hidden: CGFloat, always: CGFloat) {
        if arranging { return (NSStatusItem.variableLength, NSStatusItem.variableLength) }
        guard capability == .byPosition else { return (1, 1) }
        let widths = screenWidths.filter { $0.isFinite && $0 > 40 }
        guard let width = widths.min() else { return (1, 1) }
        // The modern layout's threshold is a candidate strategy. Physical
        // acceptance is required before selecting byPosition on that OS.
        let expanded: CGFloat = modern ? max(1, width / 2 - 20) : 10_000
        return (reveal == .collapsed ? expanded : 8,
                alwaysEnabled && reveal != .all ? expanded : 8)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
            || sender !== toggle?.button {
            contextMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
        } else if isArranging { onFinishArrange?() }
        else { onToggle?(event?.modifierFlags.contains(.option) == true) }
    }
}
