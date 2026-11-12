import AppKit
import FluxCore

/// What the Menu Bar page can do right now. The parent decides it.
public enum MenuBarPageMode: Equatable, Sendable {
    /// macOS hides icons per app (macOS 27 path).
    case perApplication
    /// Hiding depends on icon position (macOS 14 to 26 path).
    case byPosition
    /// Flux has no Accessibility grant, so it cannot read the menu bar.
    case needsAccessibility
    /// macOS did not confirm hiding. All icons stay visible.
    case paused
    /// A fixed error code from the parent. Never free text from the OS.
    case failed(code: String)

    public init(_ capability: MenuBarCapability) {
        switch capability {
        case .perApplication: self = .perApplication
        case .byPosition: self = .byPosition
        case .unavailable: self = .paused
        }
    }
}

/// The result of applying a saved choice in macOS. This is separate from
/// the saved group: a group is what the user chose, a result is what macOS did.
public enum MenuBarApplyResult: Equatable, Sendable {
    /// The parent is applying the choice. The UI shows static text, no spinner.
    case applying
    /// Flux asked macOS, but no read-back confirmed it.
    case asked
    /// A fresh policy read-back matched the choice. Only this shows "Saved in macOS".
    case savedInMacOS
    /// By-position mode: the choice is saved, but the icon was not moved yet.
    case notMovedYet
    /// macOS did not confirm. A fixed error code from the parent.
    case failed(code: String)
}

/// One app in the menu bar. The parent builds it from its local inventory.
@MainActor
public struct MenuBarAppRow {
    public let id: ApplicationID
    /// Local display name from the app bundle. Never sent anywhere by FluxUI.
    public var name: String
    /// App icon from the local bundle. No Screen Recording needed.
    public var icon: NSImage?
    /// Optional real menu bar glyph, only after the user asked for previews.
    public var preview: NSImage?
    public var iconCount: Int
    public var group: MenuBarGroup
    /// System and Flux items cannot change group. The row is read-only.
    public var isFixed: Bool
    /// Same bundle ID no longer matches its saved signing requirement.
    public var needsIdentityReview: Bool
    public var result: MenuBarApplyResult?

    public init(
        id: ApplicationID,
        name: String,
        icon: NSImage? = nil,
        preview: NSImage? = nil,
        iconCount: Int = 1,
        group: MenuBarGroup = .shown,
        isFixed: Bool? = nil,
        needsIdentityReview: Bool = false,
        result: MenuBarApplyResult? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.preview = preview
        self.iconCount = iconCount
        self.group = group
        self.isFixed = isFixed ?? id.isManagedBySystem
        self.needsIdentityReview = needsIdentityReview
        self.result = result
    }
}

/// One real status item in the layout editor, in menu bar order.
@MainActor
public struct MenuBarLayoutTile {
    public let id: MenuBarItemID
    /// The owner app's local name. Several items of one app share it.
    public var name: String
    /// The real menu bar image when Screen Recording is on, else the app icon.
    public var image: NSImage?
    public var group: MenuBarGroup
    public var isMovable: Bool
    /// False for items macOS keeps drawn: they move only within Visible.
    public var canHide: Bool

    public init(id: MenuBarItemID, name: String, image: NSImage? = nil, group: MenuBarGroup = .shown,
                isMovable: Bool? = nil, canHide: Bool? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.group = group
        self.isMovable = isMovable ?? !id.application.isManagedBySystem
        self.canHide = canHide ?? id.application.canBeHidden
    }
}

/// The state of the last move the editor asked for.
public enum MenuBarMoveStatus: Equatable, Sendable {
    case moving(name: String, attempt: Int)
    case moved(name: String)
    case failed(name: String, MenuBarMoveFailure)
}

/// Saved Menu Bar options outside the app list. The parent reads them from
/// `Preferences` and sends them back after each change. FluxUI never writes them.
public struct MenuBarOptions: Equatable, Sendable {
    /// Mirrors `Preferences.autoRehide`. Default on.
    public var autoRehide: Bool
    /// Mirrors `Preferences.autoRehideDelay`, in seconds. Default 8.
    public var autoRehideDelay: TimeInterval
    /// Mirrors `Preferences.iconStyle`. Default chevron.
    public var iconStyle: MenuBarIcon
    /// Compact spacing as the parent last read it. Nil hides the row,
    /// because Core has no saved key for it. The parent owns the macOS value.
    public var compactSpacing: Bool?

    public init(autoRehide: Bool = true, autoRehideDelay: TimeInterval = 8, iconStyle: MenuBarIcon = .chevron, compactSpacing: Bool? = nil) {
        self.autoRehide = autoRehide
        self.autoRehideDelay = autoRehideDelay
        self.iconStyle = iconStyle
        self.compactSpacing = compactSpacing
    }

    /// Delay choices. The old Settings range was 2 to 30 seconds.
    static let delayRange: ClosedRange<TimeInterval> = 2...30
    static let delayChoices: [TimeInterval] = [2, 3, 5, 8, 10, 15, 20, 30]

    /// The choices plus the saved value, so an old saved value still shows.
    var delayOptions: [TimeInterval] {
        let saved = min(max(autoRehideDelay, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        return Array(Set(Self.delayChoices + [saved])).sorted()
    }
}

/// Requests for the saved Menu Bar options. Each one only asks the parent.
public enum MenuBarOptionAction: Equatable, Sendable {
    case setAlwaysHiddenEnabled(Bool)
    case setAutoRehide(Bool)
    /// Always within 2 to 30 seconds.
    case setAutoRehideDelay(TimeInterval)
    case setIconStyle(MenuBarIcon)
    case setCompactSpacing(Bool)
}

/// Full page state. The parent sends a new value after every change.
@MainActor
public struct MenuBarPageState {
    public var mode: MenuBarPageMode
    public var rows: [MenuBarAppRow]
    /// Show the Always Hidden lane. Mirrors `Preferences.alwaysHiddenEnabled`.
    public var alwaysHiddenEnabled: Bool
    /// The parent is reading the menu bar. Shown as static text.
    public var isRefreshing: Bool
    /// The guided ⌘-drag card is open.
    public var isArranging: Bool
    /// Access was lost, but a saved layout still hides icons.
    public var savedLayoutStillApplies: Bool
    /// Real previews are on for this page visit.
    public var showsRealIcons: Bool
    public var options: MenuBarOptions
    /// Real items in menu bar order, for the layout editor.
    public var tiles: [MenuBarLayoutTile]
    /// False when the last read found no Accessibility grant.
    public var layoutAccessible: Bool
    public var moveStatus: MenuBarMoveStatus?

    public init(
        mode: MenuBarPageMode,
        rows: [MenuBarAppRow] = [],
        alwaysHiddenEnabled: Bool = true,
        isRefreshing: Bool = false,
        isArranging: Bool = false,
        savedLayoutStillApplies: Bool = false,
        showsRealIcons: Bool = false,
        options: MenuBarOptions = MenuBarOptions(),
        tiles: [MenuBarLayoutTile] = [],
        layoutAccessible: Bool = true,
        moveStatus: MenuBarMoveStatus? = nil
    ) {
        self.mode = mode
        self.rows = rows
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.isRefreshing = isRefreshing
        self.isArranging = isArranging
        self.savedLayoutStillApplies = savedLayoutStillApplies
        self.showsRealIcons = showsRealIcons
        self.options = options
        self.tiles = tiles
        self.layoutAccessible = layoutAccessible
        self.moveStatus = moveStatus
    }
}

/// Requests from the page. Each closure only asks the parent. The parent owns
/// the backend, deadlines, undo of a saved choice and the next state.
@MainActor
public struct MenuBarPageActions {
    public var assign: (ApplicationID, MenuBarGroup) -> Void
    /// Start guided arrange: the parent reveals all icons and sets `isArranging`.
    public var beginArrange: () -> Void
    /// Done or Esc. The parent reads positions and clears `isArranging`.
    public var endArrange: () -> Void
    /// The user asked for real icon previews. The parent owns Screen Recording.
    public var showRealIcons: () -> Void
    public var refresh: () -> Void
    public var openAccessibilitySettings: () -> Void
    public var checkAccessibility: () -> Void
    public var reviewIdentity: (ApplicationID) -> Void
    /// Saved option changes. The parent saves to `Preferences` and sends new state.
    public var setOption: (MenuBarOptionAction) -> Void
    /// Move one item in the real menu bar. The parent reports progress in `moveStatus`.
    public var moveItem: (MenuBarItemMove) -> Void

    public init(
        assign: @escaping (ApplicationID, MenuBarGroup) -> Void,
        beginArrange: @escaping () -> Void,
        endArrange: @escaping () -> Void,
        showRealIcons: @escaping () -> Void,
        refresh: @escaping () -> Void,
        openAccessibilitySettings: @escaping () -> Void,
        checkAccessibility: @escaping () -> Void,
        reviewIdentity: @escaping (ApplicationID) -> Void,
        setOption: @escaping (MenuBarOptionAction) -> Void,
        moveItem: @escaping (MenuBarItemMove) -> Void = { _ in }
    ) {
        self.assign = assign
        self.beginArrange = beginArrange
        self.endArrange = endArrange
        self.showRealIcons = showRealIcons
        self.refresh = refresh
        self.openAccessibilitySettings = openAccessibilitySettings
        self.checkAccessibility = checkAccessibility
        self.reviewIdentity = reviewIdentity
        self.setOption = setOption
        self.moveItem = moveItem
    }
}

extension MenuBarGroup {
    var title: String {
        switch self {
        case .shown: L("menuBar.group.visible", "Visible")
        case .hidden: L("menuBar.group.hidden", "Hidden")
        case .alwaysHidden: L("menuBar.group.alwaysHidden", "Always Hidden")
        }
    }

    var accessibilityName: String { title }

    /// One line under each strip title.
    var stripHelp: String {
        switch self {
        case .shown: L("menuBar.strip.visible.help", "Always in the menu bar.")
        case .hidden: L("menuBar.strip.hidden.help", "Shown when you click the Flux chevron.")
        case .alwaysHidden: L("menuBar.strip.always.help", "Shown when you Option-click the chevron.")
        }
    }
}

extension MenuBarIcon {
    var title: String {
        switch self {
        case .chevron: L("menuBar.icon.chevron", "Chevron")
        case .dot: L("menuBar.icon.dot", "Dot")
        case .line: L("menuBar.icon.line", "Line")
        }
    }
}

enum MenuBarText {
    static func mode(_ mode: MenuBarPageMode) -> String {
        switch mode {
        case .perApplication: L("menuBar.mode.perApp", "Hiding works per app. All icons from one app share a group.")
        case .byPosition: L("menuBar.mode.byPosition", "Hiding works by position. Moving an icon here also moves it in the menu bar.")
        case .needsAccessibility: L("menuBar.mode.access", "To read your menu bar, Flux needs Accessibility.")
        case .paused: L("menuBar.mode.paused", "Hiding is paused. macOS did not confirm the change.")
        case .failed("hidingUnavailable"): L("menuBar.mode.hidingUnavailable", "This macOS version has no menu bar hiding Flux can use. All icons stay visible.")
        case .failed("hidingRefused"): L("menuBar.mode.hidingRefused", "macOS did not confirm hiding. All icons stay visible. Flux tries again when you change a group.")
        case .failed("previewNoEligibleItems"): L("menuBar.mode.previewEmpty", "Real menu icons could not be captured. App icons are shown instead.")
        case .failed("previewUnavailable"): L("menuBar.mode.previewUnavailable", "Real menu icons are unavailable. App icons are shown instead.")
        case .failed("previewPermissionRequired"): L("menuBar.mode.previewPermission", "Allow Screen Recording to show real menu icons. App icons are shown instead.")
        case .failed(let code): String(format: L("menuBar.mode.failed", "Flux can't read the menu bar (%@)."), code)
        }
    }

    static func result(_ result: MenuBarApplyResult, row: MenuBarAppRow) -> String {
        switch result {
        case .applying: String(format: L("menuBar.result.applying", "Applying to %@…"), row.name)
        case .asked: String(format: L("menuBar.result.asked", "Flux asked macOS to apply %@ to %@."), row.group.accessibilityName, row.name)
        case .savedInMacOS: String(format: L("menuBar.result.saved", "Saved in macOS: %@ is %@."), row.name, row.group.accessibilityName)
        case .notMovedYet: String(format: L("menuBar.result.notMoved", "Saved as %@. Drag the icon into that group to move it."), row.group.accessibilityName)
        case .failed(let code): String(format: L("menuBar.result.failed", "macOS did not confirm the change for %@ (%@)."), row.name, code)
        }
    }

    static func move(_ status: MenuBarMoveStatus) -> String {
        switch status {
        case .moving(let name, let attempt):
            attempt <= 1 ? String(format: L("menuBar.move.moving", "Moving %@…"), name)
                : String(format: L("menuBar.move.retry", "Moving %@, try %ld of 3…"), name, attempt)
        case .moved(let name): String(format: L("menuBar.move.done", "Moved %@."), name)
        case .failed(let name, let failure): moveFailure(failure, name: name)
        }
    }

    static func moveFailure(_ failure: MenuBarMoveFailure, name: String) -> String {
        switch failure {
        case .accessibilityRequired: L("menuBar.move.access", "Flux needs Accessibility to move icons.")
        case .itemGone: String(format: L("menuBar.move.gone", "%@ is no longer in the menu bar."), name)
        case .itemLocked: String(format: L("menuBar.move.locked", "macOS keeps %@ in place."), name)
        case .neighbourGone: String(format: L("menuBar.move.neighbour", "The icons next to %@ changed. Try again."), name)
        case .alwaysHiddenOff: L("menuBar.move.alwaysOff", "Turn on the Always Hidden group first.")
        case .hidingUnavailable: L("menuBar.move.noHiding", "Flux can't hide icons right now, so they all stay visible.")
        case .boundaryUnavailable: L("menuBar.move.boundary", "Flux could not read these icons beside its chevron. Try again.")
        case .inputBusy: L("menuBar.move.input", "Let go of the mouse and keys, then try again.")
        case .groupNotSaved("identityReviewRequired"):
            String(format: L("menuBar.move.review", "Review %@ first. Its signing identity changed."), name)
        case .groupNotSaved("identityUnavailable"):
            String(format: L("menuBar.move.checking", "Flux is still checking %@. Try again in a moment."), name)
        case .groupNotSaved:
            String(format: L("menuBar.move.notSaved", "Flux could not save the group for %@."), name)
        case .notAccepted:
            String(format: L("menuBar.move.refused", "macOS did not move %@ after 3 tries. Try again."), name)
        }
    }

    static func count(_ count: Int) -> String {
        count == 1
            ? L("menuBar.count.one", "1 icon")
            : String(format: L("menuBar.count.many", "%ld icons, move together"), count)
    }
}
