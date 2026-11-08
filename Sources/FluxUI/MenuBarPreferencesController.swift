import AppKit
import FluxCore

/// Settings › Menu Bar page.
///
/// The parent creates it in the Settings page factory, sends state with
/// `update(_:)` and drops it when Settings discards the page. The page has
/// no timers, no capture and no backend. Search filters rows locally.
@MainActor
public final class MenuBarPreferencesController: NSViewController, SettingsPageFocus, NSSearchFieldDelegate {
    public private(set) var state: MenuBarPageState
    private let actions: MenuBarPageActions

    private let searchField = NSSearchField()
    private let modeLabel = FluxUIStyle.label("", secondary: true)
    private let statusLabel = FluxUIStyle.label("", style: .callout, secondary: true)
    private let reviewStack = FluxUIStyle.vstack([])
    private let lanesStack = FluxUIStyle.vstack([], spacing: 16)
    private let toolsStack = FluxUIStyle.hstack([])
    private let arrangeCard = ArrangeCardView()
    private var accessCard: PermissionCardView?
    private var laneViews: [MenuBarGroup: LaneView] = [:]
    private var rowViews: [ApplicationID: MenuBarRowView] = [:]
    private var query = ""
    private var announced = ""
    private weak var contentStack: NSStackView?

    public var preferredFirstResponder: NSView? { searchField }

    public init(state: MenuBarPageState, actions: MenuBarPageActions) {
        self.state = state
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        searchField.placeholderString = L("menuBar.search", "Search apps")
        searchField.setAccessibilityLabel(L("menuBar.search", "Search apps"))
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)

        statusLabel.setAccessibilityRole(.staticText)

        let arrange = FluxUIStyle.button(L("menuBar.arrange", "Arrange in Menu Bar…"), target: self, action: #selector(beginArrange))
        let preview = FluxUIStyle.button(L("menuBar.realIcons", "Show Real Icons…"), target: self, action: #selector(showRealIcons))
        preview.toolTip = L("menuBar.realIcons.help", "Uses Screen Recording to show each icon as it looks in your menu bar. Only while this page is open.")
        let refresh = FluxUIStyle.button(L("menuBar.refresh", "Refresh"), target: self, action: #selector(refresh))
        [arrange, preview, refresh].forEach(toolsStack.addArrangedSubview)

        arrangeCard.onDone = { [weak self] in self?.actions.endArrange() }

        for group in MenuBarGroup.allCases {
            let lane = LaneView(group: group)
            laneViews[group] = lane
            lanesStack.addArrangedSubview(lane)
        }

        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = FluxUIStyle.vstack([modeLabel, searchField, reviewStack, arrangeCard, lanesStack, statusLabel, toolsStack], spacing: 14)
        toolsStack.setHuggingPriority(.defaultLow, for: .horizontal)
        contentStack = content
        view = FluxUIStyle.page(content)
        render()
    }

    /// Applies a new state. Row views are kept by `ApplicationID`, so the
    /// focused control keeps focus when a row changes lane or name.
    public func update(_ newState: MenuBarPageState) {
        state = newState
        if isViewLoaded { render() }
    }

    override public func cancelOperation(_ sender: Any?) {
        if state.isArranging { actions.endArrange() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    // MARK: Rendering

    private func render() {
        let focusedID = focusedRowID()
        let usable = state.mode != .needsAccessibility
        modeLabel.stringValue = MenuBarText.mode(state.mode)
        if state.mode == .needsAccessibility, state.savedLayoutStillApplies {
            modeLabel.stringValue = L("menuBar.mode.lostAccess", "Flux can't read icons. Your saved layout still hides them.")
        }
        renderAccessCard(visible: !usable)
        searchField.isHidden = !usable
        lanesStack.isHidden = !usable
        toolsStack.isHidden = !usable
        arrangeCard.isHidden = !(usable && state.isArranging)

        let known = Set(state.rows.map(\.id))
        for (id, view) in rowViews where !known.contains(id) {
            view.removeFromSuperview()
            rowViews[id] = nil
        }
        laneViews[.alwaysHidden]?.isHidden = !state.alwaysHiddenEnabled

        let needle = query.lowercased()
        var perLane: [MenuBarGroup: [MenuBarRowView]] = [:]
        var reviewRows: [NSView] = []
        for row in state.rows {
            let view = rowViews[row.id] ?? makeRowView(row.id)
            view.apply(row, showsPreview: state.showsRealIcons, alwaysHiddenEnabled: state.alwaysHiddenEnabled)
            let matches = needle.isEmpty || row.name.lowercased().contains(needle) || row.id.rawValue.lowercased().contains(needle)
            view.isHidden = !matches
            let lane: MenuBarGroup = (row.group == .alwaysHidden && !state.alwaysHiddenEnabled) ? .hidden : row.group
            perLane[lane, default: []].append(view)
            if row.needsIdentityReview { reviewRows.append(makeReviewRow(row)) }
        }
        for group in MenuBarGroup.allCases {
            laneViews[group]?.setRows(perLane[group] ?? [], searching: !needle.isEmpty)
        }
        reviewStack.setViews(reviewRows, in: .top)
        reviewStack.isHidden = reviewRows.isEmpty || !usable

        statusLabel.stringValue = statusText()
        statusLabel.isHidden = statusLabel.stringValue.isEmpty || !usable
        if !statusLabel.isHidden, statusLabel.stringValue != announced {
            announced = statusLabel.stringValue
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [
                .announcement: statusLabel.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }

        if let focusedID, let row = rowViews[focusedID], let window = view.window {
            window.makeFirstResponder(row.groupControl)
        }
    }

    private func statusText() -> String {
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
            message: L("menuBar.access.body", "To read your menu bar, Flux needs Accessibility. Go to System Settings › Privacy & Security › Accessibility."),
            actionTitle: L("menuBar.access.open", "Open Settings"),
            secondaryTitle: L("menuBar.access.check", "Check Again")
        ))
        card.onAction = { [weak self] in self?.actions.openAccessibilitySettings() }
        card.onSecondary = { [weak self] in self?.actions.checkAccessibility() }
        content.insertArrangedSubview(card, at: 1)
        accessCard = card
    }

    private func makeRowView(_ id: ApplicationID) -> MenuBarRowView {
        let view = MenuBarRowView(id: id)
        view.onChoose = { [weak self] id, group in
            guard let self, let row = self.state.rows.first(where: { $0.id == id }), !row.isFixed else { return }
            if row.group != group { self.actions.assign(id, group) }
        }
        rowViews[id] = view
        return view
    }

    private func makeReviewRow(_ row: MenuBarAppRow) -> NSView {
        let text = FluxUIStyle.label(String(format: L("menuBar.review.text", "%@ · different signer than before"), row.name))
        let button = ReviewButton(title: L("menuBar.review", "Review…"), target: self, action: #selector(review(_:)))
        button.applicationID = row.id
        button.setAccessibilityLabel(String(format: L("menuBar.review.ax", "Review %@"), row.name))
        let image = NSImageView(image: FluxUIStyle.symbol("exclamationmark.shield", label: "") ?? NSImage())
        image.setAccessibilityElement(false)
        return FluxUIStyle.group(FluxUIStyle.hstack([image, text, button]))
    }

    private func focusedRowID() -> ApplicationID? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        return rowViews.first(where: { responder.isDescendant(of: $0.value) })?.key
    }

    // MARK: Actions

    @objc private func searchChanged() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        render()
    }

    @objc private func beginArrange() { actions.beginArrange() }
    @objc private func showRealIcons() { actions.showRealIcons() }
    @objc private func refresh() { actions.refresh() }
    @objc private func review(_ sender: ReviewButton) {
        if let id = sender.applicationID { actions.reviewIdentity(id) }
    }
}

// MARK: - Views

private final class ReviewButton: NSButton {
    var applicationID: ApplicationID?
}

@MainActor
private final class LaneView: NSView {
    private let rows: NSStackView = {
        let stack = FluxUIStyle.vstack([], spacing: 0)
        stack.alignment = .width
        return stack
    }()
    private let empty: NSTextField
    private let header: NSTextField

    init(group: MenuBarGroup) {
        header = FluxUIStyle.label(group.laneTitle, style: .headline)
        header.setAccessibilityRole(.staticText)
        empty = FluxUIStyle.label(L("menuBar.lane.empty", "No apps"), style: .callout, secondary: true)
        super.init(frame: .zero)
        let box = FluxUIStyle.group(FluxUIStyle.vstack([rows, empty], spacing: 0))
        let stack = FluxUIStyle.vstack([header, box], spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(group.laneTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setRows(_ views: [MenuBarRowView], searching: Bool) {
        if rows.arrangedSubviews != views { rows.setViews(views, in: .top) }
        let visible = views.contains { !$0.isHidden }
        empty.stringValue = searching ? L("menuBar.lane.noMatch", "No matches") : L("menuBar.lane.empty", "No apps")
        empty.isHidden = visible
    }
}

@MainActor
final class MenuBarRowView: NSView {
    let id: ApplicationID
    let groupControl = NSSegmentedControl(
        labels: MenuBarGroup.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil
    )
    var onChoose: ((ApplicationID, MenuBarGroup) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = FluxUIStyle.label("", wraps: false)
    private let detailLabel = FluxUIStyle.label("", style: .caption1, secondary: true, wraps: false)
    private let fixedLabel = FluxUIStyle.label(L("menuBar.fixed", "Managed by macOS"), style: .callout, secondary: true, wraps: false)

    init(id: ApplicationID) {
        self.id = id
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        nameLabel.toolTip = nil
        fixedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        groupControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        groupControl.setContentHuggingPriority(.required, for: .horizontal)
        groupControl.target = self
        groupControl.action = #selector(choose)
        groupControl.segmentStyle = .automatic
        groupControl.selectedSegmentBezelColor = FluxUIStyle.accent
        for (index, group) in MenuBarGroup.allCases.enumerated() {
            groupControl.setToolTip(group.accessibilityName, forSegment: index)
        }

        let text = FluxUIStyle.vstack([nameLabel, detailLabel], spacing: 1)
        text.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let spacer = FluxUIStyle.spacer()
        let stack = FluxUIStyle.hstack([iconView, text, spacer, fixedLabel, groupControl], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ row: MenuBarAppRow, showsPreview: Bool, alwaysHiddenEnabled: Bool) {
        iconView.image = (showsPreview ? row.preview : nil) ?? row.icon
            ?? FluxUIStyle.symbol("app.dashed", label: row.name)
        nameLabel.stringValue = row.name
        nameLabel.toolTip = row.name
        detailLabel.stringValue = MenuBarText.count(row.iconCount)
        let index = MenuBarGroup.allCases.firstIndex(of: row.group) ?? 0
        if groupControl.selectedSegment != index { groupControl.selectedSegment = index }
        groupControl.setEnabled(alwaysHiddenEnabled, forSegment: 2)
        groupControl.isHidden = row.isFixed
        fixedLabel.isHidden = !row.isFixed
        let groupName = row.group.accessibilityName
        groupControl.setAccessibilityLabel(String(format: L("menuBar.row.controlAX", "Group for %@"), row.name))
        setAccessibilityLabel(String(format: L("menuBar.row.ax", "%@, %@, %@"), row.name, MenuBarText.count(row.iconCount), groupName))
    }

    @objc private func choose() {
        let index = groupControl.selectedSegment
        guard MenuBarGroup.allCases.indices.contains(index) else { return }
        onChoose?(id, MenuBarGroup.allCases[index])
    }
}

@MainActor
private final class ArrangeCardView: NSView {
    var onDone: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let title = FluxUIStyle.label(L("menuBar.arrange.title", "Arrange in the menu bar"), style: .headline)
        let body = FluxUIStyle.label(L("menuBar.arrange.body", "Hold ⌘ and drag icons in the menu bar. Press Esc or Done when finished. Flux reads the new positions when you finish. Flux does not move icons for you."), secondary: true)
        let done = NSButton(title: L("menuBar.arrange.done", "Done"), target: nil, action: nil)
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(finish)
        let box = FluxUIStyle.group(FluxUIStyle.vstack([title, body, FluxUIStyle.hstack([done, FluxUIStyle.spacer()])]))
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("menuBar.arrange.title", "Arrange in the menu bar"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func finish() { onDone?() }
}
