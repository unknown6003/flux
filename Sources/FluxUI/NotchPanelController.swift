import AppKit
import FluxCore
import QuartzCore

extension Widget {
    var displayName: String {
        switch self {
        case .nowPlaying: L("notch.nowPlaying", "Now Playing")
        case .shelf: L("notch.shelf", "File Shelf")
        case .calendar: L("notch.calendar", "Calendar")
        case .mirror: L("notch.mirror", "Mirror")
        case .clipboard: L("notch.clipboard", "Clipboard")
        }
    }
}

/// Pure geometry for the notch panel. The parent passes screen values it read
/// from `NSScreen` (`frame`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`).
/// On a display without a notch, `cameraWidth` is zero.
public struct NotchGeometry: Equatable, Sendable {
    public static let wingExtent: CGFloat = 40
    public static let maximumExpandedWidth: CGFloat = 440

    public var screenFrame: CGRect
    /// Width of the camera housing. Zero when the display has no notch.
    public var cameraWidth: CGFloat
    /// Height of the menu bar area that holds the notch.
    public var topInset: CGFloat

    public init(screenFrame: CGRect, cameraWidth: CGFloat, topInset: CGFloat) {
        self.screenFrame = screenFrame
        self.cameraWidth = max(0, cameraWidth)
        self.topInset = max(0, topInset)
    }

    /// Builds geometry from the two auxiliary areas beside the notch.
    public init(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, menuBarHeight: CGFloat) {
        if let left = topLeftArea, let right = topRightArea {
            self.init(screenFrame: screenFrame, cameraWidth: right.minX - left.maxX, topInset: max(left.height, right.height))
        } else {
            self.init(screenFrame: screenFrame, cameraWidth: 0, topInset: menuBarHeight)
        }
    }

    public var hasNotch: Bool { cameraWidth > 0 }

    /// The camera area. Content never goes here.
    public var cameraRect: CGRect {
        CGRect(x: screenFrame.midX - cameraWidth / 2, y: screenFrame.maxY - topInset, width: cameraWidth, height: topInset)
    }

    /// Compact state: the notch plus up to 40 pt on each side.
    public func wingRect(extent: CGFloat = NotchGeometry.wingExtent) -> CGRect {
        let side = min(max(0, extent), NotchGeometry.wingExtent)
        let width = cameraWidth + side * 2
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - topInset, width: width, height: topInset)
    }

    /// Expanded state, up to 440 pt wide and never wider than the screen.
    public func expandedRect(contentHeight: CGFloat) -> CGRect {
        let width = min(NotchGeometry.maximumExpandedWidth, screenFrame.width)
        let height = topInset + max(0, contentHeight)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }
}

/// The black notch shape. It is always black, in light and dark appearance.
@MainActor
final class NotchShapeView: NSView {
    var bottomRadius: CGFloat = 28 { didSet { needsLayout = true } }
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = NSColor.black.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = Self.path(in: bounds, radius: bottomRadius)
        CATransaction.commit()
    }

    static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.height / 2, rect.width / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Expanded notch content: a tab strip and exactly one widget.
///
/// The parent owns the panel window, hover and hotkey. It sets this
/// controller as the window content, and supplies each widget controller from
/// `makeWidget`. On a switch or close, the previous widget controller is
/// removed and released after `onWillSwitch` / `onWillDismiss`, so the parent
/// can stop camera or media work first. This controller has no timers.
@MainActor
public final class NotchPanelController: NSViewController {
    public typealias WidgetFactory = @MainActor (Widget) -> NSViewController

    /// Called before the current widget is removed for another one.
    public var onWillSwitch: ((_ from: Widget?, _ to: Widget) -> Void)?
    /// Called before the panel content is removed. The parent then closes the window.
    public var onWillDismiss: ((Widget?) -> Void)?
    /// Called with `.calendar` before the Duo companion is made, and with nil
    /// after it is removed. The primary widget's own callbacks still run.
    public var onCompanionChange: ((Widget?) -> Void)?
    /// Called after a change that alters the fitting height, such as Duo on
    /// or off. The window owner refits once. Nothing here repeats.
    public var onLayoutChange: (() -> Void)?

    /// Share of the content width that the Duo calendar pane takes.
    public static let duoCompanionFraction: CGFloat = 0.36
    /// Space between the two Duo panes.
    public static let duoGap: CGFloat = 12

    public private(set) var widgets: [Widget]
    public private(set) var current: Widget?
    public let geometry: NotchGeometry

    private let makeWidget: WidgetFactory
    private let tabs = NSSegmentedControl()
    private let scroll = NotchPanelScrollView()
    private let container = NotchPanelDocumentView()
    private var heightLimit: NSLayoutConstraint?
    private let cameraSpacer = NSView()
    private weak var child: NSViewController?
    private weak var companionChild: NSViewController?
    private var paneConstraints: [NSLayoutConstraint] = []
    private var dismissed = false

    /// The window owner's height cap for the whole panel, camera gap and tab
    /// strip included. Widget content taller than what is left scrolls inside
    /// the panel. The tab strip stays outside the scroll area.
    public var maximumHeight: CGFloat = 10_000 {
        didSet { heightLimit?.constant = maximumHeight.isFinite ? max(0, maximumHeight) : 10_000 }
    }

    /// The parent's Duo request. See `setDuo(_:)`.
    public private(set) var isDuoRequested = false
    /// The widget shown beside the current one, or nil.
    public var companion: Widget? { companionChild == nil ? nil : .calendar }

    /// - Parameters:
    ///   - widgets: enabled widgets in the saved order.
    ///   - geometry: from the display that shows the panel.
    public init(widgets: [Widget], geometry: NotchGeometry, makeWidget: @escaping WidgetFactory) {
        self.widgets = widgets
        self.geometry = geometry
        self.makeWidget = makeWidget
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = NotchShapeView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(L("notch.panel", "Notch panel"))

        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setAccessibilityLabel(L("notch.tabs", "Notch widgets"))
        tabs.selectedSegmentBezelColor = FluxUIStyle.accent

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false
        scroll.setAccessibilityIdentifier("flux.notch.content")
        scroll.setAccessibilityLabel(L("notch.content", "Widget content"))
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container

        for view in [cameraSpacer, tabs, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        cameraSpacer.setAccessibilityElement(false)
        // The scroll view wants the document height, below the priority at
        // which AppKit resizes a window. A tall widget therefore cannot push
        // the window past `maximumHeight`; the excess scrolls instead.
        let preferred = scroll.heightAnchor.constraint(equalTo: container.heightAnchor)
        preferred.priority = NSLayoutConstraint.Priority(490)
        let limit = root.heightAnchor.constraint(lessThanOrEqualToConstant: maximumHeight)
        heightLimit = limit
        NSLayoutConstraint.activate([
            cameraSpacer.topAnchor.constraint(equalTo: root.topAnchor),
            cameraSpacer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cameraSpacer.heightAnchor.constraint(equalToConstant: geometry.topInset),
            cameraSpacer.widthAnchor.constraint(equalToConstant: geometry.cameraWidth),
            tabs.topAnchor.constraint(equalTo: cameraSpacer.bottomAnchor, constant: 6),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            preferred,
            limit,
            root.widthAnchor.constraint(lessThanOrEqualToConstant: NotchGeometry.maximumExpandedWidth),
        ])
        view = root
        reloadTabs()
    }

    /// Shows one widget. The previous widget is removed first.
    public func show(_ widget: Widget) {
        guard !dismissed, widgets.contains(widget), widget != current else { return }
        onWillSwitch?(current, widget)
        guard !dismissed else { return }
        removeChild()
        let controller = makeWidget(widget)
        addChild(controller)
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        child = controller
        current = widget
        if let index = widgets.firstIndex(of: widget) { tabs.selectedSegment = index }
        if duoApplies { addCompanion() } else { layoutPanes() }
        fadeContainer()
    }

    /// Duo view: Now Playing with Calendar beside it. The parent decides
    /// when Duo applies, from the saved `flux.notch.duo` value, Calendar
    /// access and a relevant event. The panel shows Duo only while Now
    /// Playing is the current widget and Calendar is in `widgets`. Both
    /// panes come from `makeWidget`, so they hold only parent data.
    /// Turning Duo off removes only the calendar pane.
    public func setDuo(_ requested: Bool) {
        guard requested != isDuoRequested else { return }
        isDuoRequested = requested
        guard !dismissed, child != nil else { return }
        reconcileCompanion()
    }

    /// Replaces the widget list, for example after a Settings change.
    public func setWidgets(_ newWidgets: [Widget]) {
        widgets = Array(newWidgets.reduce(into: [Widget]()) { result, widget in
            if !result.contains(widget) { result.append(widget) }
        })
        if isViewLoaded { reloadTabs() }
        if child != nil, !dismissed { reconcileCompanion() }
        if let current, !widgets.contains(current) {
            if let first = widgets.first {
                show(first)
            } else {
                dismiss()
            }
        } else if current == nil, let first = widgets.first, isViewLoaded {
            show(first)
        }
    }

    /// Terminal for this presentation. Late AppKit appearance callbacks must
    /// not recreate a widget after the parent stopped its service.
    public func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        onWillDismiss?(current)
        removeChild()
        current = nil
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        guard !dismissed else { return }
        if current == nil, let first = widgets.first { show(first) }
        view.window?.makeFirstResponder(tabs)
    }

    override public func viewDidDisappear() {
        super.viewDidDisappear()
        if child != nil { dismiss() }
    }

    override public func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: step(-1)
        case .rightArrow?: step(1)
        default: super.keyDown(with: event)
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        dismiss()
        view.window?.orderOut(nil)
    }

    private func step(_ delta: Int) {
        guard !widgets.isEmpty else { return }
        let index = current.flatMap { widgets.firstIndex(of: $0) } ?? 0
        let next = (index + delta + widgets.count) % widgets.count
        show(widgets[next])
    }

    private func reloadTabs() {
        container.wantsLayer = true
        tabs.segmentCount = widgets.count
        for (index, widget) in widgets.enumerated() {
            tabs.setLabel(widget.displayName, forSegment: index)
            tabs.setWidth(0, forSegment: index)
        }
        tabs.isHidden = widgets.count < 2
        if let current, let index = widgets.firstIndex(of: current) { tabs.selectedSegment = index }
    }

    private func removeChild() {
        removeCompanion()
        guard let controller = child else { return }
        NSLayoutConstraint.deactivate(paneConstraints)
        paneConstraints = []
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        child = nil
    }

    private var duoApplies: Bool {
        isDuoRequested && !dismissed && current == .nowPlaying && widgets.contains(.calendar)
    }

    private func reconcileCompanion() {
        let wanted = duoApplies
        guard wanted != (companionChild != nil) else { return }
        if wanted { addCompanion() } else { removeCompanion(); layoutPanes() }
        fadeContainer()
        onLayoutChange?()
    }

    private func addCompanion() {
        guard companionChild == nil else { layoutPanes(); return }
        onCompanionChange?(.calendar)
        // The callback may have dismissed the panel or changed Duo.
        guard duoApplies, child != nil else { onCompanionChange?(nil); layoutPanes(); return }
        let controller = makeWidget(.calendar)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        companionChild = controller
        layoutPanes()
    }

    private func removeCompanion() {
        guard let controller = companionChild else { return }
        let view = controller.view
        let hadFocus = (view.window?.firstResponder as? NSView).map { $0.isDescendant(of: view) } ?? false
        view.removeFromSuperview()
        controller.removeFromParent()
        companionChild = nil
        if hadFocus, let window = self.view.window { window.makeFirstResponder(tabs) }
        onCompanionChange?(nil)
    }

    /// Pins the primary widget alone, or beside the companion.
    private func layoutPanes() {
        NSLayoutConstraint.deactivate(paneConstraints)
        paneConstraints = []
        guard let primary = child?.view else { return }
        var list = [
            primary.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            primary.topAnchor.constraint(equalTo: container.topAnchor),
            primary.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        if let side = companionChild?.view {
            list += [
                side.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: Self.duoGap),
                side.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                side.topAnchor.constraint(equalTo: container.topAnchor),
                side.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
                side.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: Self.duoCompanionFraction,
                                            constant: -Self.duoGap * Self.duoCompanionFraction),
            ]
        } else {
            list.append(primary.trailingAnchor.constraint(equalTo: container.trailingAnchor))
        }
        NSLayoutConstraint.activate(list)
        paneConstraints = list
    }

    private func fadeContainer() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        container.layer?.add(fade, forKey: nil)
    }

    /// Readback for tests and the window owner: the visible widget area and
    /// the full widget content height.
    public var contentViewportHeight: CGFloat { scroll.contentView.bounds.height }
    public var contentDocumentHeight: CGFloat { container.frame.height }

    @objc private func tabChanged() {
        let index = tabs.selectedSegment
        guard widgets.indices.contains(index) else { return }
        show(widgets[index])
    }
}

/// Top-down document so short content sits under the tab strip.
@MainActor
final class NotchPanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Left and Right switch tabs even while focus is inside a widget.
@MainActor
final class NotchPanelScrollView: NSScrollView {
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .rightArrow?: nextResponder?.keyDown(with: event)
        default: super.keyDown(with: event)
        }
    }
}
