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
        [notchSection(), behaviorSection(), widgetSection(), clipboardSection(), activitySection(), accessSection()]
    }

    private func notchSection() -> NSView {
        let on = toggle("notch.enabled", state.isEnabled) { [weak self] in self?.send(.setEnabled($0)) }
        return FluxUIStyle.section(L("notch.header", "Notch"), [
            FluxUIStyle.row(L("notch.enabled", "Enable the notch panel"), helper: L(
                "notch.enabled.helper",
                "Opens a panel with widgets and live activities from the top of the screen. Turning it off keeps your choices."
            ), control: on),
        ])
    }

    private func behaviorSection() -> NSView {
        let on = state.isEnabled
        let trigger = popup("notch.trigger", [
            (L("notch.trigger.hover", "Hover"), ExpansionTrigger.hover),
            (L("notch.trigger.click", "Click"), ExpansionTrigger.click),
        ], selected: state.trigger, enabled: on) { [weak self] in self?.send(.setTrigger($0)) }
        var delays: [Double] = [0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.0]
        if !delays.contains(state.hoverCloseDelay) { delays = (delays + [state.hoverCloseDelay]).sorted() }
        let delay = popup("notch.closeDelay", delays.map { (String(format: L("notch.closeDelay.value", "%.1f s"), $0), $0) },
                          selected: state.hoverCloseDelay, enabled: on && state.trigger == .hover) { [weak self] in
            self?.send(.setHoverCloseDelay($0))
        }
        let fullscreen = toggle("notch.fullscreen", state.showInFullscreen, enabled: on) { [weak self] in
            self?.send(.setShowInFullscreen($0))
        }
        return FluxUIStyle.section(L("notch.behavior", "Behavior"), [
            FluxUIStyle.row(L("notch.trigger", "Open with"), helper: L("notch.trigger.helper", "Hover opens when the pointer reaches the notch. Click opens only on a click."), control: trigger),
            FluxUIStyle.row(L("notch.closeDelay", "Close delay"), helper: L("notch.closeDelay.helper", "How long the panel stays open after the pointer leaves. Used with Hover."), control: delay),
            FluxUIStyle.row(L("notch.fullscreen", "Show while in fullscreen apps"), control: fullscreen),
        ])
    }

    private func widgetSection() -> NSView {
        let on = state.isEnabled
        var rows: [NSView] = state.widgets.enumerated().map { index, item in
            widgetRow(item, index: index, enabled: on)
        }
        let duo = toggle("notch.duo", state.duoEnabled, enabled: on && state.isOn(.nowPlaying) && state.isOn(.calendar)) { [weak self] in
            self?.send(.setDuoEnabled($0))
        }
        rows.append(FluxUIStyle.row(L("notch.duo", "Duo view"), helper: L(
            "notch.duo.helper", "Shows Now Playing and Calendar side by side. Needs both widgets on."
        ), control: duo))
        let expiry = popup("notch.shelf.expiry", [
            (L("notch.shelf.never", "Never"), ShelfExpiry.never),
            (L("notch.shelf.1", "1 day"), .oneDay),
            (L("notch.shelf.3", "3 days"), .threeDays),
            (L("notch.shelf.7", "7 days"), .sevenDays),
        ], selected: state.shelfExpiry, enabled: on && state.isOn(.shelf)) { [weak self] in self?.send(.setShelfExpiry($0)) }
        rows.append(FluxUIStyle.row(L("notch.shelf.expiry", "Auto-clear File Shelf"), helper: L(
            "notch.shelf.expiry.helper", "Removes shelf items after this time."
        ), control: expiry))
        return FluxUIStyle.section(L("notch.widgets", "Widgets"), rows)
    }

    private func widgetRow(_ item: WidgetPreference, index: Int, enabled: Bool) -> NSView {
        let widget = item.widget, name = widget.displayName, id = "notch.widget.\(widget.rawValue)"
        let onOff = toggle(id, item.isEnabled, enabled: enabled) { [weak self] in self?.send(.setWidgetEnabled(widget, $0)) }
        onOff.setAccessibilityLabel(name)
        let up = orderButton(id + ".up", "chevron.up", String(format: L("notch.widget.up", "Move %@ earlier"), name),
                             enabled: enabled && index > 0) { [weak self] in self?.send(.moveWidgetUp(widget)) }
        let down = orderButton(id + ".down", "chevron.down", String(format: L("notch.widget.down", "Move %@ later"), name),
                               enabled: enabled && index < state.widgets.count - 1) { [weak self] in self?.send(.moveWidgetDown(widget)) }
        let controls = FluxUIStyle.hstack([onOff, up, down], spacing: 6)
        controls.setAccessibilityElement(false)
        return FluxUIStyle.row(name, helper: widgetHelper(widget), control: controls)
    }

    private func orderButton(_ id: String, _ symbol: String, _ label: String, enabled: Bool, _ handler: @escaping () -> Void) -> NSButton {
        let control = button(id, label, enabled: enabled, handler)
        control.title = ""
        control.image = FluxUIStyle.symbol(symbol, label: label)
        control.imagePosition = .imageOnly
        control.toolTip = label
        control.setAccessibilityLabel(label)
        return control
    }

    private func widgetHelper(_ widget: Widget) -> String {
        switch widget {
        case .nowPlaying: L("notch.widget.nowPlaying.helper", "Media controls and artwork for what is playing.")
        case .shelf: L("notch.widget.shelf.helper", "Drag files onto the notch to keep them here.")
        case .calendar: L("notch.widget.calendar.helper", "Today's and tomorrow's events. Needs Calendar access.")
        case .mirror: L("notch.widget.mirror.helper", "A camera preview. The camera runs only while Mirror is open.")
        case .clipboard: L("notch.widget.clipboard.helper", "Collects what you copy. While this is on, Flux checks the clipboard for new copies. Off stops the checks.")
        }
    }

    private func clipboardSection() -> NSView {
        let collecting = state.isEnabled && state.isOn(.clipboard)
        let save = toggle("notch.clipboard.save", state.clipboardSaving, enabled: collecting) { [weak self] in
            self?.send(.setClipboardSaving($0))
        }
        let clear = button("notch.clipboard.clear", L("notch.clipboard.clear", "Clear Saved History")) { [weak self] in
            self?.confirmClear()
        }
        return FluxUIStyle.section(L("notch.clipboard.header", "Clipboard"), [
            FluxUIStyle.row(L("notch.clipboard.save", "Save clipboard history"), helper: L(
                "notch.clipboard.save.helper",
                "Keeps text, links and colors on this Mac between launches. Image and file contents are never saved."
            ), control: save),
            FluxUIStyle.row(L("notch.clipboard.clear.title", "Saved history"), helper: L(
                "notch.clipboard.clear.helper", "Removes the current history and its saved copy."
            ), control: clear),
        ])
    }

    private func confirmClear() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("notch.clipboard.confirm", "Clear clipboard history?")
        alert.informativeText = L("notch.clipboard.clear.helper", "Removes the current history and its saved copy.")
        alert.addButton(withTitle: L("notch.clipboard.confirm.clear", "Clear History")).hasDestructiveAction = true
        alert.addButton(withTitle: L("notch.clipboard.confirm.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.send(.clearClipboardHistory) }
        }
    }

    private func activitySection() -> NSView {
        let rows: [NSView] = NotchActivity.allCases.map { activity in
            let (key, title, helper) = activityText(activity)
            let control = toggle("notch.activity.\(key)", state.enabledActivities.contains(activity), enabled: state.isEnabled) { [weak self] in
                self?.send(.setActivity(activity, $0))
            }
            return FluxUIStyle.row(title, helper: helper, control: control)
        }
        return FluxUIStyle.section(L("notch.activities", "Live Activities"), rows)
    }

    private func activityText(_ activity: NotchActivity) -> (String, String, String) {
        switch activity {
        case .battery: ("battery", L("notch.activity.battery", "Battery"), L("notch.activity.battery.helper", "Shows a wing when you plug in, unplug or run low."))
        case .bluetooth: ("bluetooth", L("notch.activity.bluetooth", "Bluetooth devices"), L("notch.activity.bluetooth.helper", "Shows a wing when an accessory connects or disconnects."))
        case .calendarEvent: ("calendarEvent", L("notch.activity.calendarEvent", "Upcoming event alerts"), L("notch.activity.calendarEvent.helper", "Shows a wing before an event starts. Needs Calendar access."))
        case .timer: ("timer", L("notch.activity.timer", "Timer live display"), L("notch.activity.timer.helper", "Shows a countdown while a timer runs, and an alert when it ends."))
        case .soundHUD: ("soundHUD", L("notch.activity.soundHUD", "Volume & ringer visualizer"), L("notch.activity.soundHUD.helper", "Shows volume and mute changes in the notch. Needs Accessibility access."))
        }
    }

    private func accessSection() -> NSView {
        let rows: [NSView] = NotchAccessKind.allCases.map { kind in
            let (key, title, user) = accessText(kind)
            let status = state.access(kind)
            var control: NSButton?
            if status == .notAsked {
                control = button("notch.access.\(key)", L("notch.access.allow", "Allow"), enabled: state.isEnabled) { [weak self] in self?.send(.requestAccess(kind)) }
            } else if status == .denied {
                control = button("notch.access.\(key)", L("notch.access.open", "Open Settings"), enabled: state.isEnabled) { [weak self] in self?.send(.openAccessSettings(kind)) }
            }
            control?.setAccessibilityLabel(String(format: L("notch.access.ax", "%@ access"), title))
            return FluxUIStyle.row(title, helper: user + " " + statusText(status), control: control)
        }
        return FluxUIStyle.section(L("notch.access", "Access"), rows)
    }

    private func accessText(_ kind: NotchAccessKind) -> (String, String, String) {
        switch kind {
        case .calendar: ("calendar", L("notch.access.calendar", "Calendar"), L("notch.access.calendar.use", "Used by Calendar and event alerts."))
        case .camera: ("camera", L("notch.access.camera", "Camera"), L("notch.access.camera.use", "Used by Mirror."))
        case .accessibility: ("accessibility", L("notch.access.accessibility", "Accessibility"), L("notch.access.accessibility.use", "Used by the volume visualizer."))
        }
    }

    private func statusText(_ status: NotchAccessStatus) -> String {
        switch status {
        case .allowed: L("notch.access.allowed", "Allowed.")
        case .notAsked: L("notch.access.notAsked", "Not asked yet. Flux asks only when you press Allow.")
        case .denied: L("notch.access.denied", "Not allowed. Change it in System Settings › Privacy & Security.")
        case .unavailable: L("notch.access.unavailable", "Not available on this Mac.")
        }
    }
}
