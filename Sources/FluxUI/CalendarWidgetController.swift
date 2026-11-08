import AppKit
import FluxCore

/// A calendar color as plain sRGB values, so state stays `Sendable`.
public struct CalendarWidgetColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// One event row. The parent maps its agenda snapshot to these values.
public struct CalendarWidgetEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var location: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var color: CalendarWidgetColor?

    public init(id: String, title: String, location: String? = nil, start: Date, end: Date,
                isAllDay: Bool = false, color: CalendarWidgetColor? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.color = color
    }
}

public enum CalendarWidgetState: Equatable, Sendable {
    /// Access is allowed and the first read has not arrived. Shows a fixed
    /// "Loading events" card with no button and no error.
    case loading
    /// Events already split by the parent into today and tomorrow, in display order.
    /// Both empty shows "No upcoming events".
    case events(today: [CalendarWidgetEvent], tomorrow: [CalendarWidgetEvent])
    /// The parent has not got Calendar access. Nothing claims access is given.
    case needsPermission
    /// macOS denied access, or the store cannot be read.
    case unavailable
}

public enum CalendarWidgetAction: Equatable, Sendable {
    case requestAccess
    case openSettings
    case checkAgain
    /// The user chose "N more". The parent opens Calendar on that day.
    case openCalendar(CalendarWidgetDay)
}

public enum CalendarWidgetDay: Equatable, Sendable {
    case today, tomorrow
}

/// The Calendar notch widget. It shows today and tomorrow from parent values.
/// It has no EventKit, clock or timer. Times use the user's locale and time zone.
@MainActor
public final class CalendarWidgetController: NSViewController {
    /// Rows shown per day before a "N more" line, to keep the panel compact.
    public static let maximumRowsPerDay = 4

    public private(set) var state: CalendarWidgetState
    private let onAction: @MainActor (CalendarWidgetAction) -> Void
    private let list = FluxUIStyle.vstack([], spacing: 6)
    private let card = NotchCardHost()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    public init(state: CalendarWidgetState, onAction: @escaping @MainActor (CalendarWidgetAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        let root = NotchWidgetStyle.root()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(Widget.calendar.displayName)
        NotchWidgetStyle.pinTop(FluxUIStyle.vstack([list, card], spacing: 0), in: root)
        view = root
        apply()
    }

    /// Replaces the state. Rows are rebuilt only when the events change.
    public func update(_ newState: CalendarWidgetState) {
        guard newState != state else { return }
        state = newState
        if isViewLoaded { apply() }
    }

    private func apply() {
        let focus = view.window?.firstResponder
        defer { NotchWidgetStyle.restoreFocus(focus, in: view.window) }
        switch state {
        case .loading:
            showCard("loading", .init(symbolName: "calendar", title: L("calendar.loading", "Loading events\u{2026}"),
                     message: L("calendar.loading.message", "Flux is reading your calendars.")),
                     onAction: nil)
        case .needsPermission:
            showCard("needsPermission", .init(symbolName: "calendar",
                     title: L("calendar.permission", "See your events"),
                     message: L("calendar.permission.message", "Flux can show your upcoming events right in the notch."),
                     actionTitle: L("calendar.grant", "Grant Access")),
                     onAction: { [weak self] in self?.onAction(.requestAccess) })
        case .unavailable:
            showCard("unavailable", .init(symbolName: "calendar.badge.exclamationmark",
                     title: L("calendar.unavailable", "Calendar isn\u{2019}t available"),
                     message: L("calendar.unavailable.message", "Flux can\u{2019}t read your calendars. Check access in System Settings."),
                     actionTitle: L("calendar.openSettings", "Open Settings"),
                     secondaryTitle: L("calendar.checkAgain", "Check Again")),
                     onAction: { [weak self] in self?.onAction(.openSettings) },
                     onSecondary: { [weak self] in self?.onAction(.checkAgain) })
        case let .events(today, tomorrow) where today.isEmpty && tomorrow.isEmpty:
            showCard("empty", .empty(symbolName: "calendar", message: L("calendar.empty", "No upcoming events")), onAction: nil)
        case let .events(today, tomorrow):
            card.hide()
            list.isHidden = false
            for view in list.arrangedSubviews { view.removeFromSuperview() }
            let days: [(CalendarWidgetDay, String, [CalendarWidgetEvent])] = [
                (.today, L("calendar.today", "Today"), today),
                (.tomorrow, L("calendar.tomorrow", "Tomorrow"), tomorrow),
            ]
            for (day, title, events) in days where !events.isEmpty {
                list.addArrangedSubview(dayHeader(title))
                for event in events.prefix(Self.maximumRowsPerDay) { list.addArrangedSubview(row(event)) }
                let more = events.count - Self.maximumRowsPerDay
                if more > 0 { list.addArrangedSubview(moreButton(more, day: day, dayTitle: title)) }
            }
            view.setAccessibilityLabel(String(format: L("calendar.summary", "%@: %d today, %d tomorrow"),
                                              Widget.calendar.displayName, today.count, tomorrow.count))
        }
    }

    private func showCard(_ key: String, _ content: PermissionCardView.Content,
                          onAction: (() -> Void)?, onSecondary: (() -> Void)? = nil) {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        list.isHidden = true
        card.show(key: key, content, onAction: onAction, onSecondary: onSecondary)
        view.setAccessibilityLabel("\(Widget.calendar.displayName): \(content.title.isEmpty ? content.message : content.title)")
    }

    /// "N more" opens Calendar, so no hidden event is out of reach.
    private func moreButton(_ count: Int, day: CalendarWidgetDay, dayTitle: String) -> NSButton {
        let title = String(format: L("calendar.more", "%d more"), count)
        let button = NSButton(title: title, target: self, action: #selector(moreClicked(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .preferredFont(forTextStyle: .caption1)
        button.contentTintColor = FluxUIStyle.accent
        button.alignment = .left
        button.tag = day == .today ? 0 : 1
        button.setAccessibilityLabel(String(format: L("calendar.more.label", "%@: %d more events. Open in Calendar"),
                                            dayTitle, count))
        button.toolTip = L("calendar.openCalendar", "Open in Calendar")
        return button
    }

    @objc private func moreClicked(_ sender: NSButton) {
        onAction(.openCalendar(sender.tag == 0 ? .today : .tomorrow))
    }

    private func dayHeader(_ title: String) -> NSTextField {
        let header = FluxUIStyle.label(title.uppercased(), style: .caption2, secondary: true, wraps: false)
        header.setAccessibilityRole(.staticText)
        header.setAccessibilityLabel(title)
        return header
    }

    private func row(_ event: CalendarWidgetEvent) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (event.color?.nsColor ?? FluxUIStyle.accent).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        let time = event.isAllDay
            ? L("calendar.allDay", "All-day")
            : "\(timeFormatter.string(from: event.start)) \u{2013} \(timeFormatter.string(from: event.end))"
        let title = event.title.isEmpty ? L("calendar.untitled", "No title") : event.title
        let titleLabel = FluxUIStyle.label(title, wraps: false)
        var detail = time
        if let location = event.location, !location.isEmpty { detail += " \u{00B7} \(location)" }
        let detailLabel = FluxUIStyle.label(detail, style: .caption1, secondary: true, wraps: false)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        NotchWidgetStyle.fillWidth(titleLabel, detailLabel)

        let texts = FluxUIStyle.vstack([titleLabel, detailLabel], spacing: 1)
        let row = FluxUIStyle.hstack([dot, texts], spacing: 8)
        row.alignment = .firstBaseline
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("\(title), \(detail)")
        for child in [titleLabel, detailLabel] { child.setAccessibilityElement(false) }
        return row
    }
}
