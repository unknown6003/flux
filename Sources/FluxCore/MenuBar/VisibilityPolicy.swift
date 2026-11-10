import Foundation

public struct ApplicationID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 255,
              rawValue.contains("."),
              rawValue.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
        else { return nil }
        self.rawValue = rawValue
    }

    /// Owners whose items macOS keeps in place: Flux's own controls, the
    /// clock and Control Center button (MenuBarAgent), the Control Center
    /// modules, and session agents. Other Apple apps, such as the keyboard
    /// input menu or Passwords, move and hide like any app.
    public var isManagedBySystem: Bool { Self.pinnedBySystem.contains(rawValue) }

    /// False for pinned owners and for items macOS draws even under a hiding
    /// restriction. On macOS 27 the keyboard input menu and Search stay drawn
    /// whatever the allow list says (CI probe), so they move but do not hide.
    public var canBeHidden: Bool { !isManagedBySystem && !Self.alwaysDrawnBySystem.contains(rawValue) }

    public static let alwaysDrawnBySystem: Set<String> = ["com.apple.TextInputMenuAgent", "com.apple.campo"]

    public static let pinnedBySystem: Set<String> = [
        "com.flux.menubar", "com.apple.MenuBarAgent", "com.apple.controlcenter",
        "com.apple.systemuiserver", "com.apple.loginwindow",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
    ]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = ApplicationID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid application identifier")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MenuBarGroup: String, CaseIterable, Sendable, Codable {
    case shown, hidden, alwaysHidden
}

public enum MenuBarReveal: Sendable {
    case collapsed, hidden, all
}

public enum MenuBarCapability: Sendable {
    case perApplication, byPosition, unavailable
}

public enum VisibilityPolicyError: Error {
    case invalidStoredLayout, protectedApplication
}

/// Saved visibility choices contain no icon coordinates or physical-order promises.
public struct VisibilityPolicy: Sendable, Equatable {
    private var hidden: Set<ApplicationID>
    private var alwaysHidden: Set<ApplicationID>

    public init() {
        hidden = []
        alwaysHidden = []
    }

    /// Preserve the old format: Always Hidden is a subset of Hidden.
    public init(legacyPropertyList value: Any?) throws {
        self.init()
        guard let value else { return }
        guard let dictionary = value as? [String: Any],
              let hiddenIDs = dictionary["hidden"] as? [String],
              let alwaysIDs = dictionary["alwaysHidden"] as? [String]
        else { throw VisibilityPolicyError.invalidStoredLayout }
        let hidden = hiddenIDs.compactMap(ApplicationID.init(rawValue:))
        let always = alwaysIDs.compactMap(ApplicationID.init(rawValue:))
        guard hidden.count == hiddenIDs.count, always.count == alwaysIDs.count else {
            throw VisibilityPolicyError.invalidStoredLayout
        }
        self.hidden = Set(hidden)
        alwaysHidden = Set(always).intersection(self.hidden)
    }

    public func group(for application: ApplicationID) -> MenuBarGroup {
        guard application.canBeHidden else { return .shown }
        if alwaysHidden.contains(application) { return .alwaysHidden }
        return hidden.contains(application) ? .hidden : .shown
    }

    public mutating func assign(_ application: ApplicationID, to group: MenuBarGroup) throws {
        guard application.canBeHidden || group == .shown else { throw VisibilityPolicyError.protectedApplication }
        switch group {
        case .shown:
            hidden.remove(application)
            alwaysHidden.remove(application)
        case .hidden:
            hidden.insert(application)
            alwaysHidden.remove(application)
        case .alwaysHidden:
            hidden.insert(application)
            alwaysHidden.insert(application)
        }
    }

    public func concealedApplications(
        running: Set<ApplicationID>, reveal: MenuBarReveal, alwaysHiddenEnabled: Bool
    ) -> Set<ApplicationID> {
        let requested: Set<ApplicationID>
        switch reveal {
        case .collapsed: requested = hidden
        case .hidden: requested = alwaysHiddenEnabled ? alwaysHidden : []
        case .all: requested = []
        }
        return requested.intersection(running).filter(\.canBeHidden)
    }

    /// Merge only Flux-owned fields. Keep future fields in the existing dictionary.
    public func legacyPropertyList(updating original: [String: Any] = [:]) -> [String: Any] {
        var result = original
        result["hidden"] = hidden.map(\.rawValue).sorted()
        result["alwaysHidden"] = alwaysHidden.map(\.rawValue).sorted()
        return result
    }
}
