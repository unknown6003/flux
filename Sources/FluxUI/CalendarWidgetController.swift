import AppKit
import FluxCore
import SwiftUI

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

/// The Calendar notch widget: the 0.21.35 SwiftUI agenda. Events are grouped
/// by the parent into today and tomorrow by their start day.
@MainActor
public final class CalendarWidgetController: NSViewController, NotchContentProviding {
    public static let maximumRowsPerDay = 20

    public private(set) var state: CalendarWidgetState
    let model: CalendarNotchModel

    public init(state: CalendarWidgetState, onAction: @escaping @MainActor (CalendarWidgetAction) -> Void) {
        self.state = state
        model = CalendarNotchModel(state: state, onAction: onAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = NotchWidgetHost.make(notchContent())
    }

    public func notchContent() -> AnyView { AnyView(CalendarExpandedView(model: model)) }

    public func update(_ newState: CalendarWidgetState) {
        guard newState != state else { return }
        state = newState
        model.state = newState
    }
}
