import AppKit
import FluxCore
import FluxPlatform
import FluxUI

/// The Flux chevron's right-click menu. A left click shows and hides icons.
public enum MenuBarAction: Sendable {
    case settings, quit
}

/// The native menu-bar owner supplies real state and all of its actions.
/// It must revoke previews on editor exit and finish restoration before stop
/// returns. No default implementation can silently omit an action.
@MainActor public protocol MenuBarService: AnyObject {
    var onAction: (@MainActor (MenuBarAction) -> Void)? { get set }
    var onChange: (@MainActor () -> Void)? { get set }
    var onOverflow: (@MainActor (Int) -> Void)? { get set }
    var state: MenuBarPageState { get }
    func start()
    func stop() async throws
    func refresh()
    func configure()
    func setEditorVisible(_ visible: Bool)
    func toggle()
    func showAll()
    func assign(_ application: ApplicationID, to group: MenuBarGroup)
    func beginArrange()
    func endArrange()
    func showRealIcons()
    func checkAccessibility()
    func reviewIdentity(_ application: ApplicationID)
    func setCompactSpacing(_ enabled: Bool)
    /// Move one real item, as the layout editor asked. Progress is in `state.moveStatus`.
    func moveItem(_ move: MenuBarItemMove)
    /// The app menu, shown by a right-click on the notch as in 0.21.35.
    func contextMenu() -> NSMenu?
}

public extension MenuBarService {
    func contextMenu() -> NSMenu? { nil }
}

/// Construction reads no media and creates no window or private space.
/// The demand-owned handle opens and closes the optional lock-screen bridge.
@MainActor public protocol LockScreenService: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    var onTransport: (@MainActor (LockScreenTransportAction) -> Void)? { get set }
    var capability: LockScreenCapability { get }
    var failureCode: String? { get }
    func makeHandle() throws -> any FeatureServiceHandle
    func configure()
    func checkAgain()
    func setPhase(_ phase: SessionPhase)
    func receive(_ event: WidgetEvent)
    func updateActivity(_ item: ActivityItem?)
    func stop()
}

public enum ApplicationFailure: Sendable {
    case settings(SettingsFailure), runtime(NotchRuntimeFailure)
    case menuBarRecovery, timer, link

    var usageCode: UsageEvent.Failure {
        switch self {
        case .settings(.saveFailed): .preferenceSaveFailed
        case .settings(.loginItemFailed): .loginItemFailed
        case .settings(.clipboardFailed): .clipboardFailed
        case .runtime: .serviceUnavailable
        case .menuBarRecovery: .visibilityUnavailable
        case .timer: .timerFailed
        case .link: .linkFailed
        }
    }
}
