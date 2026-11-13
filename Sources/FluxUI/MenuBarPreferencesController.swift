import AppKit
import FluxCore

/// Settings › Menu Bar page.
///
/// The parent creates it in the Settings page factory, sends state with
/// `update(_:)` and drops it when Settings discards the page. The page has
/// no timers, no capture and no backend. The layout editor shows the real
/// items; each drop or menu choice asks the parent to move one item.
@MainActor
public final class MenuBarPreferencesController: NSViewController, SettingsPageFocus {
    public private(set) var state: MenuBarPageState
    private let actions: MenuBarPageActions

    private let arrangeButton = NSButton(title: "", target: nil, action: nil)
    private let arrangeHelp = FluxUIStyle.label("", style: .callout, secondary: true)
    private let modeLabel = FluxUIStyle.label("", secondary: true)
    private let statusLabel = FluxUIStyle.label("", style: .callout, secondary: true)
    private let reviewStack = FluxUIStyle.vstack([])
    private let editor = MenuBarLayoutEditorView()
    private let editorSection = FluxUIStyle.vstack([], spacing: 6)
    private let toolsStack = FluxUIStyle.hstack([])
    private var realIconsButton: NSButton?
    private let previewModeLabel = FluxUIStyle.label("", style: .callout, secondary: true)
    private let optionsStack = FluxUIStyle.vstack([], spacing: 20)
    private let optionControls = FormControls()
    private var shownOptions: (MenuBarOptions, Bool)?
    private var accessCard: PermissionCardView?
    private var announced = ""
    private weak var contentStack: NSStackView?

    public var preferredFirstResponder: NSView? { editor.firstTile }

    public init(state: MenuBarPageState, actions: MenuBarPageActions) {
        self.state = state
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        statusLabel.setAccessibilityRole(.staticText)
        editor.onMove = { [weak self] in self?.actions.moveItem($0) }
        editor.onArrangeRequested = { [weak self] in self?.actions.beginArrange() }
        editor.onInteractionChanged = { [weak self] in self?.actions.editorInteractionChanged($0) }

        let title = FluxUIStyle.label(L("menuBar.layout.title", "Menu Bar Layout"), style: .headline)
        title.setAccessibilityRole(.staticText)
        let help = FluxUIStyle.label(L("menuBar.layout.help",
            "Drag icons between groups, or right-click to choose a group. To change icon order, choose Arrange in Menu Bar."),
            style: .callout, secondary: true)
        let revealHelp = FluxUIStyle.label(L("menuBar.layout.revealHelp",
            "These lanes show saved groups. Opening this page shows all icons temporarily. Use the chevron to show or hide them. Option-click it to show all icons before moving a hidden icon."),
            style: .callout, secondary: true)
        arrangeButton.target = self
        arrangeButton.action = #selector(toggleArrange)
        arrangeButton.setAccessibilityIdentifier("menuBar.arrange")
        [title, help, arrangeButton, arrangeHelp, revealHelp, editor].forEach(editorSection.addArrangedSubview)
        editorSection.setCustomSpacing(12, after: revealHelp)

        let preview = FluxUIStyle.button(L("menuBar.realIcons", "Show Real Icons…"), target: self, action: #selector(showRealIcons))
        preview.toolTip = L("menuBar.realIcons.help", "Uses Screen Recording to show each icon as it looks in your menu bar.")
        let refresh = FluxUIStyle.button(L("menuBar.refresh", "Refresh"), target: self, action: #selector(refresh))
        [preview, refresh, FluxUIStyle.spacer()].forEach(toolsStack.addArrangedSubview)
        realIconsButton = preview

        let content = FluxUIStyle.vstack([modeLabel, reviewStack, editorSection, statusLabel, previewModeLabel, toolsStack, optionsStack], spacing: 14)
        contentStack = content
        view = FluxUIStyle.page(content)
        render()
    }

    /// Applies a new state. Tile views are kept by item, so focus survives a move.
    public func update(_ newState: MenuBarPageState) {
        state = newState
        if isViewLoaded { render() }
    }

    // MARK: Rendering

    private var moving: Bool {
        if case .moving = state.moveStatus { return true }
        return false
    }

    private func render() {
        let needsAccess = state.mode == .needsAccessibility || !state.layoutAccessible
        modeLabel.stringValue = MenuBarText.mode(state.mode)
        if state.mode == .needsAccessibility, state.savedLayoutStillApplies {
            modeLabel.stringValue = L("menuBar.mode.lostAccess", "Flux can't read icons. Your saved layout still hides them.")
        }
        modeLabel.isHidden = needsAccess
        renderAccessCard(visible: needsAccess)
        editorSection.isHidden = needsAccess
        toolsStack.isHidden = needsAccess
        previewModeLabel.isHidden = needsAccess
        previewModeLabel.stringValue = state.showsRealIcons
            ? L("menuBar.preview.captured", "Captured previews. Icons without a capture use app icons.")
            : L("menuBar.preview.apps", "App icons are shown. Choose Show Real Icons for menu-bar previews.")
        realIconsButton?.isHidden = state.showsRealIcons
        arrangeButton.title = state.isArranging ? L("menuBar.arrange.done", "Done Arranging") : L("menuBar.layout.arrange", "Arrange in Menu Bar…")
        arrangeButton.isEnabled = !moving && !state.isRefreshing
        arrangeHelp.isHidden = !state.isArranging
        arrangeHelp.stringValue = L("menuBar.arrange.help", "Hold Command and drag the actual icons left or right in the menu bar at the top of your screen. Keep them in the bar. Click Done Arranging or the Flux checkmark when finished. Group choices below stay saved.")
        editor.update(tiles: state.tiles, alwaysHiddenEnabled: state.alwaysHiddenEnabled,
                      busy: moving || state.isRefreshing || state.isArranging)

        let reviewRows = state.rows.filter(\.needsIdentityReview).map(makeReviewRow)
        reviewStack.setViews(reviewRows, in: .top)
        reviewStack.isHidden = reviewRows.isEmpty || needsAccess

        renderOptions()

        statusLabel.stringValue = statusText()
        statusLabel.textColor = isFailure ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = statusLabel.stringValue.isEmpty || needsAccess
        if !statusLabel.isHidden, statusLabel.stringValue != announced {
            announced = statusLabel.stringValue
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [
                .announcement: statusLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    private var isFailure: Bool {
        if case .failed = state.moveStatus { return true }
        return false
    }

    /// Saved options do not need Accessibility, so they show in every mode.
    /// The section rebuilds only when its values change, and keeps focus.
    private func renderOptions() {
        let current = (state.options, state.alwaysHiddenEnabled)
        if let shown = shownOptions, shown == current { return }
        shownOptions = current
        let focused = FormControls.focusedID(in: view.window)
        optionControls.reset()
        optionsStack.setViews(makeOptionSections(), in: .top)
        FormControls.restoreFocus(focused, in: optionsStack)
    }

    private func makeOptionSections() -> [NSView] {
        let options = state.options
        let send: (MenuBarOptionAction) -> Void = { [weak self] in self?.actions.setOption($0) }
        let always = optionControls.toggle("menuBar.option.always", state.alwaysHiddenEnabled) { send(.setAlwaysHiddenEnabled($0)) }
        let rehide = optionControls.toggle("menuBar.option.rehide", options.autoRehide) { send(.setAutoRehide($0)) }
        let delay = optionControls.popup(
            "menuBar.option.delay",
            options.delayOptions.map { (String(format: L("menuBar.option.delay.value", "%.0f s"), $0), $0) },
            selected: min(max(options.autoRehideDelay, MenuBarOptions.delayRange.lowerBound), MenuBarOptions.delayRange.upperBound),
            enabled: options.autoRehide
        ) { send(.setAutoRehideDelay($0)) }
        var behavior: [NSView] = [
            FluxUIStyle.row(L("menuBar.option.always", "Always Hidden group"), helper: L(
                "menuBar.option.always.helper", "Off moves its icons to Hidden."
            ), control: always),
            FluxUIStyle.row(L("menuBar.option.rehide", "Hide icons again"), helper: L(
                "menuBar.option.rehide.helper", "Hide shown icons again after the delay below."
            ), control: rehide),
            FluxUIStyle.row(L("menuBar.option.delay", "Delay"), control: delay),
        ]
        if let compact = options.compactSpacing {
            let spacing = optionControls.toggle("menuBar.option.spacing", compact) { send(.setCompactSpacing($0)) }
            behavior.append(FluxUIStyle.row(L("menuBar.option.spacing", "Compact icon spacing"), helper: L(
                "menuBar.option.spacing.helper", "Flux saves this in macOS. It may need a new login to apply."
            ), control: spacing))
        }
        let style = optionControls.popup(
            "menuBar.option.icon",
            MenuBarIcon.allCases.map { ($0.title, $0) },
            selected: options.iconStyle
        ) { send(.setIconStyle($0)) }
        return [
            FluxUIStyle.section(L("menuBar.options", "Behavior"), behavior),
            FluxUIStyle.section(L("menuBar.appearance", "Appearance"), [
                FluxUIStyle.row(L("menuBar.option.icon", "Flux icon in the menu bar"), control: style),
            ]),
        ]
    }

    private func statusText() -> String {
        if let status = state.moveStatus { return MenuBarText.move(status) }
        if state.isRefreshing { return L("menuBar.refreshing", "Reading the menu bar…") }
        guard let row = state.rows.last(where: { $0.result != nil }), let result = row.result else { return "" }
        return MenuBarText.result(result, row: row)
    }

    private func renderAccessCard(visible: Bool) {
        guard visible else {
            accessCard?.removeFromSuperview()
            accessCard = nil
            return
        }
        guard accessCard == nil, let content = contentStack else { return }
        let card = PermissionCardView(content: .init(
            symbolName: "hand.raised",
            title: L("menuBar.access.title", "Allow Accessibility"),
            message: L("menuBar.access.body", "Flux needs Accessibility to show and move your menu bar icons. Turn on Flux in Privacy & Security › Accessibility."),
            actionTitle: L("menuBar.access.open", "Open Accessibility Settings")
        ))
        card.onAction = { [weak self] in self?.actions.openAccessibilitySettings() }
        content.insertArrangedSubview(card, at: 1)
        accessCard = card
    }

    private func makeReviewRow(_ row: MenuBarAppRow) -> NSView {
        let text = FluxUIStyle.label(String(format: L("menuBar.review.text", "%@ · signing identity changed"), row.name))
        let button = ReviewButton(title: L("menuBar.review", "Review…"), target: self, action: #selector(review(_:)))
        button.applicationID = row.id
        button.setAccessibilityLabel(String(format: L("menuBar.review.ax", "Review %@"), row.name))
        let image = NSImageView(image: FluxUIStyle.symbol("exclamationmark.shield", label: "") ?? NSImage())
        image.setAccessibilityElement(false)
        return FluxUIStyle.group(FluxUIStyle.hstack([image, text, button]))
    }

    /// Runs one tile's right-click command by its title, as choosing it in the
    /// menu would. The CI arrange probe drives the editor through this.
    @discardableResult
    public func performTileCommand(_ title: String, for id: MenuBarItemID) -> Bool {
        _ = view
        let menu = editor.menu(for: id)
        guard let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    // MARK: Actions

    @objc private func toggleArrange() {
        if state.isArranging { actions.endArrange() } else { actions.beginArrange() }
    }
    @objc private func showRealIcons() { actions.showRealIcons() }
    @objc private func refresh() { actions.refresh() }
    @objc private func review(_ sender: ReviewButton) {
        if let id = sender.applicationID { actions.reviewIdentity(id) }
    }
}

private final class ReviewButton: NSButton {
    var applicationID: ApplicationID?
}
