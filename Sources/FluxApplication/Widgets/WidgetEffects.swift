import FluxCore
import FluxPlatform

/// A permission that a notch widget asks for from its own card.
public enum WidgetPermission: Sendable {
    case calendar, camera

    var system: SystemPermission {
        switch self {
        case .calendar: .calendar
        case .camera: .camera
        }
    }
}

/// A fixed failure code. It holds no title, path, URL, payload or OS text.
public enum WidgetFailure: String, Sendable {
    case mediaCommand = "widget.media.command"
    case mediaOpenSource = "widget.media.open"
    case calendarOpen = "widget.calendar.open"
    case clipboardCapture = "widget.clipboard.capture"
    case clipboardRestore = "widget.clipboard.restore"
    case clipboardCaptureDropped = "widget.clipboard.dropped"
    case clipboardCopy = "widget.clipboard.copy"
    case clipboardRemove = "widget.clipboard.remove"
    case clipboardClear = "widget.clipboard.clear"
    case clipboardOpenLink = "widget.clipboard.link"
    case shelfLoad = "widget.shelf.load"
    case shelfCopy = "widget.shelf.copy"
    case shelfBusy = "widget.shelf.busy"
    case shelfDropLimited = "widget.shelf.limited"
    case shelfOpen = "widget.shelf.open"
    case shelfShare = "widget.shelf.share"
    case shelfPasteboard = "widget.shelf.pasteboard"
    case shelfRemove = "widget.shelf.remove"
}

/// A state change that other app parts can use, for example the lock screen
/// or the calendar activity. Media and calendar values hold user content:
/// never pass them to telemetry.
public enum WidgetEvent: Sendable {
    case media(MediaFeedState)
    case calendar(AgendaReadResult)
    /// A shelf copy job ended. Counts only.
    case shelfCopyFinished(added: Int, failed: Int)
}

/// App work that the widgets need. Every method is required, so a missing
/// handler is a compile error and not a silent no-op. The coordinator calls
/// them on the main actor, only from a user action or a feed change.
@MainActor
public protocol WidgetEffects: AnyObject {
    /// The user pressed Allow on a widget card. Call `PermissionAccess.request`,
    /// then apply a new `FeatureDemand` with fresh camera and calendar access,
    /// so `FeatureRuntime` calls the matching `start…Feed`. Return after that.
    func requestAccess(_ permission: WidgetPermission) async
    /// Open the System Settings pane with `PermissionAccess.openSettings`. Never prompt.
    func openSettings(_ permission: WidgetPermission)
    /// The user pressed Check Again or Try Again and the service is not running.
    /// Re-apply `FeatureDemand`. If the service is still requested and absent,
    /// `FeatureRuntime.apply` creates it again through the matching `start…Feed`.
    func retry(_ service: FeatureService)
    /// Show or count the fixed code only.
    func report(_ failure: WidgetFailure)
    func widgetEvent(_ event: WidgetEvent)
}
