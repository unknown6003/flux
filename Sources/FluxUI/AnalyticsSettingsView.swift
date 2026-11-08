import AppKit

/// What the parent's `UsageCollection` reports. The view never reads or
/// shows the random ID value.
public enum AnalyticsStatus: Equatable, Sendable {
    case off
    case on
    /// The parent is saving a switch change or a reset. Static text only.
    case working
    /// A new random ID was made.
    case reset
}

/// The Analytics group for Settings › General.
///
/// It is OFF until the parent passes `.on` after a saved opt-in. The switch
/// and Reset ID only call the parent. Nothing here sends data.
@MainActor
public final class AnalyticsSettingsView: NSView {
    public var onSetEnabled: ((Bool) -> Void)?
    public var onResetID: (() -> Void)?
    public private(set) var status: AnalyticsStatus = .off

    public let toggle = NSSwitch()
    private let resetButton = NSButton(title: L("analytics.reset", "Reset ID"), target: nil, action: nil)
    private let statusLabel = FluxUIStyle.label("", style: .callout, secondary: true)

    public init(status: AnalyticsStatus = .off) {
        super.init(frame: .zero)
        let title = FluxUIStyle.label(L("analytics.title", "Share anonymous usage data"))
        toggle.target = self
        toggle.action = #selector(switchChanged)
        toggle.identifier = .init("analytics.enabled")
        toggle.setAccessibilityLabel(L("analytics.title", "Share anonymous usage data"))

        let helper = FluxUIStyle.label(L(
            "analytics.helper",
            "Helps find bugs and decide what to build. When on, Flux sends fixed feature names, results and error codes with a random ID. It never sends app names, file names, or clipboard, calendar, music or screen content."
        ), style: .callout, secondary: true)

        let idTitle = FluxUIStyle.label(L("analytics.id", "Analytics ID"))
        let idHelper = FluxUIStyle.label(L(
            "analytics.id.helper",
            "A random ID made on this Mac. It is not your name, email or device ID."
        ), style: .callout, secondary: true)
        resetButton.bezelStyle = .push
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.identifier = .init("analytics.reset")
        resetButton.setAccessibilityLabel(L("analytics.reset.ax", "Reset analytics ID"))

        let spacer1 = NSView(), spacer2 = NSView()
        [spacer1, spacer2].forEach { $0.setContentHuggingPriority(.init(1), for: .horizontal) }
        let switchRow = FluxUIStyle.hstack([title, spacer1, toggle])
        let idRow = FluxUIStyle.hstack([FluxUIStyle.vstack([idTitle, idHelper], spacing: 2), spacer2, resetButton])
        let separator = NSBox.separator()
        let stack = FluxUIStyle.vstack([switchRow, helper, separator, idRow, statusLabel], spacing: 8)
        for view in [switchRow, helper, separator, idRow, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let header = FluxUIStyle.label(L("analytics.header", "Analytics"), style: .headline)
        let box = FluxUIStyle.group(stack)
        let outer = FluxUIStyle.vstack([header, box], spacing: 6)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("analytics.header", "Analytics"))
        update(status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(_ status: AnalyticsStatus) {
        let previous = self.status
        self.status = status
        switch status {
        case .off:
            toggle.state = .off
            statusLabel.stringValue = L("analytics.status.off", "Off. Flux sends nothing. Requests already received can't be recalled.")
        case .on:
            toggle.state = .on
            statusLabel.stringValue = L("analytics.status.on", "On.")
        case .working:
            statusLabel.stringValue = L("analytics.status.working", "Saving…")
        case .reset:
            statusLabel.stringValue = L("analytics.status.reset", "New random ID made. Data sent before stays with the old ID.")
        }
        toggle.isEnabled = status != .working
        resetButton.isEnabled = status != .working
        if status != previous {
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [
                .announcement: statusLabel.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    @objc private func switchChanged() {
        onSetEnabled?(toggle.state == .on)
    }

    @objc private func reset() { onResetID?() }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
