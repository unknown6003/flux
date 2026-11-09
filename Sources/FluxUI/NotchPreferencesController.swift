import AppKit
import FluxCore

/// One widget in the saved order, with its saved switch.
public struct WidgetPreference: Equatable, Sendable {
    public let widget: Widget
    public let isEnabled: Bool

    public init(widget: Widget, isEnabled: Bool) {
        self.widget = widget
        self.isEnabled = isEnabled
    }
}

/// Shelf auto-clear. The raw value is `flux.notch.shelf.expiryDays`; 0 is Never.
public enum ShelfExpiry: Int, CaseIterable, Sendable {
    case never = 0, oneDay = 1, threeDays = 3, sevenDays = 7
}

/// A live activity switch on the Notch page.
public enum NotchActivity: CaseIterable, Sendable {
    case battery, bluetooth, calendarEvent, timer, soundHUD
}

/// A grant a notch feature uses. The parent reads it; FluxUI never asks macOS.
public enum NotchAccessKind: CaseIterable, Sendable {
    case calendar, camera, accessibility
}

/// The parent's fixed reading of one grant.
public enum NotchAccessStatus: Equatable, Sendable {
    case allowed
    case notAsked
    case denied
    case unavailable
}

/// Everything Settings › Notch shows. The parent sends a new value after each change.
public struct NotchPreferencesState: Equatable, Sendable {
    public let isEnabled: Bool
    public let trigger: ExpansionTrigger
    /// Seconds, from `flux.notch.hoverCloseDelay`.
    public let hoverCloseDelay: Double
    public let showInFullscreen: Bool
    /// All five widgets, in the saved order.
    public let widgets: [WidgetPreference]
    public let duoEnabled: Bool
    public let shelfExpiry: ShelfExpiry
    /// `flux.notch.clipboard.persistence.enabled`. Collection is the Clipboard widget switch.
    public let clipboardSaving: Bool
    public let enabledActivities: Set<NotchActivity>
    public let calendarAccess: NotchAccessStatus
    public let cameraAccess: NotchAccessStatus
    public let accessibilityAccess: NotchAccessStatus

    public init(
        isEnabled: Bool,
        trigger: ExpansionTrigger,
        hoverCloseDelay: Double,
        showInFullscreen: Bool,
        widgets: [WidgetPreference],
        duoEnabled: Bool,
        shelfExpiry: ShelfExpiry,
        clipboardSaving: Bool,
        enabledActivities: Set<NotchActivity>,
        calendarAccess: NotchAccessStatus,
        cameraAccess: NotchAccessStatus,
        accessibilityAccess: NotchAccessStatus
    ) {
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.hoverCloseDelay = hoverCloseDelay
        self.showInFullscreen = showInFullscreen
        self.widgets = widgets
        self.duoEnabled = duoEnabled
        self.shelfExpiry = shelfExpiry
        self.clipboardSaving = clipboardSaving
        self.enabledActivities = enabledActivities
        self.calendarAccess = calendarAccess
        self.cameraAccess = cameraAccess
        self.accessibilityAccess = accessibilityAccess
    }

    func isOn(_ widget: Widget) -> Bool { widgets.first { $0.widget == widget }?.isEnabled ?? false }

    func access(_ kind: NotchAccessKind) -> NotchAccessStatus {
        switch kind {
        case .calendar: calendarAccess
        case .camera: cameraAccess
        case .accessibility: accessibilityAccess
        }
    }
}

/// Requests from Settings › Notch. The parent saves, reorders and asks macOS.
public enum NotchPreferencesAction: Equatable, Sendable {
    case setEnabled(Bool)
    case setTrigger(ExpansionTrigger)
    case setHoverCloseDelay(Double)
    case setShowInFullscreen(Bool)
    /// For `.clipboard` this turns collection on or off.
    case setWidgetEnabled(Widget, Bool)
    case moveWidgetUp(Widget)
    case moveWidgetDown(Widget)
    case setDuoEnabled(Bool)
    case setShelfExpiry(ShelfExpiry)
    case setClipboardSaving(Bool)
    /// Sent only after the user confirms.
    case clearClipboardHistory
    case setActivity(NotchActivity, Bool)
    /// The user pressed Allow. The parent asks macOS now, not at launch.
    case requestAccess(NotchAccessKind)
    case openAccessSettings(NotchAccessKind)
}

/// Settings › Notch page. It only shows state and sends actions.
@MainActor
public final class NotchPreferencesController: FormPageController {
    public private(set) var state: NotchPreferencesState
    private let onAction: (NotchPreferencesAction) -> Void

    public init(state: NotchPreferencesState, onAction: @escaping (NotchPreferencesAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init()
    }

    /// Shows a new state. It never sends an action.
    public func update(state: NotchPreferencesState) {
        guard state != self.state else { return }
        self.state = state
        rebuild()
    }

    private func send(_ action: NotchPreferencesAction) { onAction(action) }

    override func makeSections() -> [NSView] {
        var sections = [notchSection(), behaviorSection(), widgetSection(), clipboardSection(), activitySection()]
        if let access = accessSection() { sections.append(access) }
        return sections
    }

    private func notchSection() -> NSView {
        FluxUIStyle.section(nil, [
            switchRow("notch.enabled", L("notch.enabled", "Notch panel"), help: L(
                "notch.enabled.helper", "Widgets and live activities at the top of the screen."
            ), isOn: state.isEnabled) { [weak self] in self?.send(.setEnabled($0)) },
        ])
    }

    private func behaviorSection() -> NSView {
        let on = state.isEnabled
        var delays: [Double] = [0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.0]
        if !delays.contains(state.hoverCloseDelay) { delays = (delays + [state.hoverCloseDelay]).sorted() }
        return FluxUIStyle.section(L("notch.behavior", "Behavior"), [
            popupRow("notch.trigger", L("notch.trigger", "Open on"), [
                (L("notch.trigger.hover", "Hover"), ExpansionTrigger.hover),
                (L("notch.trigger.click", "Click"), ExpansionTrigger.click),
            ], selected: state.trigger, enabled: on) { [weak self] in self?.send(.setTrigger($0)) },
            popupRow("notch.closeDelay", L("notch.closeDelay", "Close after the pointer leaves"),
                     delays.map { (String(format: L("notch.closeDelay.value", "%.1f s"), $0), $0) },
                     selected: state.hoverCloseDelay, enabled: on && state.trigger == .hover) { [weak self] in
                self?.send(.setHoverCloseDelay($0))
            },
            switchRow("notch.fullscreen", L("notch.fullscreen", "Show in fullscreen apps"),
                      isOn: state.showInFullscreen, enabled: on) { [weak self] in self?.send(.setShowInFullscreen($0)) },
        ])
    }

    private func widgetSection() -> NSView {
        let on = state.isEnabled
        var rows: [NSView] = state.widgets.enumerated().map { index, item in
            widgetRow(item, index: index, enabled: on)
        }
        rows.append(switchRow("notch.duo", L("notch.duo", "Duo view"), help: L(
            "notch.duo.helper", "Now Playing and Calendar side by side."
        ), isOn: state.duoEnabled, enabled: on && state.isOn(.nowPlaying) && state.isOn(.calendar)) { [weak self] in
            self?.send(.setDuoEnabled($0))
        })
        rows.append(popupRow("notch.shelf.expiry", L("notch.shelf.expiry", "Clear File Shelf after"), [
            (L("notch.shelf.never", "Never"), ShelfExpiry.never),
            (L("notch.shelf.1", "1 day"), .oneDay),
            (L("notch.shelf.3", "3 days"), .threeDays),
            (L("notch.shelf.7", "7 days"), .sevenDays),
        ], selected: state.shelfExpiry, enabled: on && state.isOn(.shelf)) { [weak self] in self?.send(.setShelfExpiry($0)) })
        return FluxUIStyle.section(L("notch.widgets", "Widgets"), rows)
    }

    private func widgetRow(_ item: WidgetPreference, index: Int, enabled: Bool) -> NSView {
        let widget = item.widget, name = widget.displayName, id = "notch.widget.\(widget.rawValue)"
        let onOff = toggle(id, item.isEnabled, enabled: enabled) { [weak self] in self?.send(.setWidgetEnabled(widget, $0)) }
        onOff.setAccessibilityLabel(name)
        let up = orderButton(id + ".up", "chevron.up", String(format: L("notch.widget.up", "Move %@ up"), name),
                             enabled: enabled && index > 0) { [weak self] in self?.send(.moveWidgetUp(widget)) }
        let down = orderButton(id + ".down", "chevron.down", String(format: L("notch.widget.down", "Move %@ down"), name),
                               enabled: enabled && index < state.widgets.count - 1) { [weak self] in self?.send(.moveWidgetDown(widget)) }
        let controls = FluxUIStyle.hstack([up, down, onOff], spacing: 4)
        controls.setCustomSpacing(12, after: down)
        controls.setAccessibilityElement(false)
        return FluxUIStyle.row(name, helper: widgetHelper(widget), control: controls)
    }

    /// A small borderless arrow, so the switches still line up on the right.
    private func orderButton(_ id: String, _ symbol: String, _ label: String, enabled: Bool, _ handler: @escaping () -> Void) -> NSButton {
        let control = button(id, label, enabled: enabled, handler)
        control.title = ""
        control.image = FluxUIStyle.symbol(symbol, label: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        control.imagePosition = .imageOnly
        control.isBordered = false
        control.bezelStyle = .accessoryBarAction
        control.contentTintColor = .secondaryLabelColor
        control.toolTip = label
        control.setAccessibilityLabel(label)
        control.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return control
    }

    private func widgetHelper(_ widget: Widget) -> String {
        switch widget {
        case .nowPlaying: L("notch.widget.nowPlaying.helper", "Media controls for what is playing.")
        case .shelf: L("notch.widget.shelf.helper", "Drop files on the notch to keep them.")
        case .calendar: L("notch.widget.calendar.helper", "Today's and tomorrow's events.")
        case .mirror: L("notch.widget.mirror.helper", "A camera preview.")
        case .clipboard: L("notch.widget.clipboard.helper", "Your recent copies.")
        }
    }

    private func clipboardSection() -> NSView {
        let collecting = state.isEnabled && state.isOn(.clipboard)
        return FluxUIStyle.section(L("notch.clipboard.header", "Clipboard"), [
            switchRow("notch.clipboard.save", L("notch.clipboard.save", "Keep history after quitting"), help: L(
                "notch.clipboard.save.helper", "Text, links and colors only."
            ), isOn: state.clipboardSaving, enabled: collecting) { [weak self] in self?.send(.setClipboardSaving($0)) },
            buttonRow("notch.clipboard.clear", L("notch.clipboard.clear.title", "Clipboard history"),
                      action: L("notch.clipboard.clear", "Clear…")) { [weak self] in self?.confirmClear() },
        ])
    }

    private func confirmClear() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("notch.clipboard.confirm", "Clear clipboard history?")
        alert.informativeText = L("notch.clipboard.confirm.detail", "This removes the history and its saved copy.")
        alert.addButton(withTitle: L("notch.clipboard.confirm.clear", "Clear History")).hasDestructiveAction = true
        alert.addButton(withTitle: L("notch.clipboard.confirm.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.send(.clearClipboardHistory) }
        }
    }

    private func activitySection() -> NSView {
        let rows: [NSView] = NotchActivity.allCases.map { activity in
            let (key, title, help) = activityText(activity)
            return switchRow("notch.activity.\(key)", title, help: help, isOn: state.enabledActivities.contains(activity),
                             enabled: state.isEnabled) { [weak self] in self?.send(.setActivity(activity, $0)) }
        }
        return FluxUIStyle.section(L("notch.activities", "Live activities"), rows)
    }

    private func activityText(_ activity: NotchActivity) -> (String, String, String) {
        switch activity {
        case .battery: ("battery", L("notch.activity.battery", "Battery"), L("notch.activity.battery.helper", "Charging and low battery."))
        case .bluetooth: ("bluetooth", L("notch.activity.bluetooth", "Bluetooth devices"), L("notch.activity.bluetooth.helper", "When a device connects or disconnects."))
        case .calendarEvent: ("calendarEvent", L("notch.activity.calendarEvent", "Upcoming events"), L("notch.activity.calendarEvent.helper", "Before an event starts."))
        case .timer: ("timer", L("notch.activity.timer", "Timer"), L("notch.activity.timer.helper", "A countdown while a timer runs."))
        case .soundHUD: ("soundHUD", L("notch.activity.soundHUD", "Volume"), L("notch.activity.soundHUD.helper", "Volume and mute changes."))
        }
    }

    /// Only grants that need a step from the user. Nil when all are set.
    private func accessSection() -> NSView? {
        let rows: [NSView] = NotchAccessKind.allCases.compactMap { kind in
            let (key, title, use) = accessText(kind)
            let control: NSButton
            switch state.access(kind) {
            case .allowed, .unavailable:
                return nil
            case .notAsked:
                control = button("notch.access.\(key)", L("notch.access.allow", "Allow"), enabled: state.isEnabled) { [weak self] in
                    self?.send(.requestAccess(kind))
                }
            case .denied:
                control = button("notch.access.\(key)", L("notch.access.open", "Open Settings"), enabled: state.isEnabled) { [weak self] in
                    self?.send(.openAccessSettings(kind))
                }
            }
            control.setAccessibilityLabel(String(format: L("notch.access.ax", "%@ access"), title))
            return FluxUIStyle.row(title, helper: use, control: control)
        }
        return rows.isEmpty ? nil : FluxUIStyle.section(L("notch.access", "Access"), rows)
    }

    private func accessText(_ kind: NotchAccessKind) -> (String, String, String) {
        switch kind {
        case .calendar: ("calendar", L("notch.access.calendar", "Calendar"), L("notch.access.calendar.use", "For the Calendar widget and event alerts."))
        case .camera: ("camera", L("notch.access.camera", "Camera"), L("notch.access.camera.use", "For Mirror."))
        case .accessibility: ("accessibility", L("notch.access.accessibility", "Accessibility"), L("notch.access.accessibility.use", "For the volume activity."))
        }
    }
}
