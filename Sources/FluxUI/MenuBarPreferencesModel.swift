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
    /// Same bundle ID with a different signer. Shows a Review button.
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

    public init(
        mode: MenuBarPageMode,
        rows: [MenuBarAppRow] = [],
        alwaysHiddenEnabled: Bool = true,
        isRefreshing: Bool = false,
        isArranging: Bool = false,
        savedLayoutStillApplies: Bool = false,
        showsRealIcons: Bool = false
    ) {
        self.mode = mode
        self.rows = rows
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.isRefreshing = isRefreshing
        self.isArranging = isArranging
        self.savedLayoutStillApplies = savedLayoutStillApplies
        self.showsRealIcons = showsRealIcons
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

    public init(
        assign: @escaping (ApplicationID, MenuBarGroup) -> Void,
        beginArrange: @escaping () -> Void,
        endArrange: @escaping () -> Void,
        showRealIcons: @escaping () -> Void,
        refresh: @escaping () -> Void,
        openAccessibilitySettings: @escaping () -> Void,
        checkAccessibility: @escaping () -> Void,
        reviewIdentity: @escaping (ApplicationID) -> Void
    ) {
        self.assign = assign
        self.beginArrange = beginArrange
        self.endArrange = endArrange
        self.showRealIcons = showRealIcons
        self.refresh = refresh
        self.openAccessibilitySettings = openAccessibilitySettings
        self.checkAccessibility = checkAccessibility
        self.reviewIdentity = reviewIdentity
    }
}

extension MenuBarGroup {
    var title: String {
        switch self {
        case .shown: L("menuBar.group.shown", "Shown")
        case .hidden: L("menuBar.group.hidden", "Hidden")
        case .alwaysHidden: L("menuBar.group.always", "Always")
        }
    }

    var laneTitle: String {
        switch self {
        case .shown: L("menuBar.lane.shown", "Shown")
        case .hidden: L("menuBar.lane.hidden", "Hidden")
        case .alwaysHidden: L("menuBar.lane.always", "Always Hidden")
        }
    }

    var accessibilityName: String {
        switch self {
        case .alwaysHidden: L("menuBar.group.alwaysAX", "Always Hidden")
        default: title
        }
    }
}

enum MenuBarText {
    static func mode(_ mode: MenuBarPageMode) -> String {
        switch mode {
        case .perApplication: L("menuBar.mode.perApp", "Hiding works per app. All icons from one app move together.")
        case .byPosition: L("menuBar.mode.byPosition", "Hiding works by position. Arrange icons in the menu bar after you change a group.")
        case .needsAccessibility: L("menuBar.mode.access", "To read your menu bar, Flux needs Accessibility.")
        case .paused: L("menuBar.mode.paused", "Hiding is paused: macOS did not confirm the change. Your icons are all visible.")
        case .failed(let code): String(format: L("menuBar.mode.failed", "Flux can't read the menu bar (%@)."), code)
        }
    }

    static func result(_ result: MenuBarApplyResult, row: MenuBarAppRow) -> String {
        switch result {
        case .applying: String(format: L("menuBar.result.applying", "Applying to %@…"), row.name)
        case .asked: String(format: L("menuBar.result.asked", "Flux asked macOS to apply %@ to %@."), row.group.accessibilityName, row.name)
        case .savedInMacOS: String(format: L("menuBar.result.saved", "Saved in macOS: %@ is %@."), row.name, row.group.accessibilityName)
        case .notMovedYet: String(format: L("menuBar.result.notMoved", "Saved as %@. Not moved yet. Use Arrange in Menu Bar…"), row.group.accessibilityName)
        case .failed(let code): String(format: L("menuBar.result.failed", "macOS did not confirm the change for %@ (%@)."), row.name, code)
        }
    }

    static func count(_ count: Int) -> String {
        count == 1
            ? L("menuBar.count.one", "1 icon")
            : String(format: L("menuBar.count.many", "%ld icons, move together"), count)
    }
}
