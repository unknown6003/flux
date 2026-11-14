import AppKit
import FluxCore

/// Access is limited to the menu bar's position file, selected by the user.
@MainActor public final class MenuBarOrderAccess {
    private let defaults: UserDefaults
    private let key: String
    private let fileURL: URL
    private var scoped: URL?
    private let message: String?
    public static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    public init(defaults: UserDefaults, file: URL = MenuBarOrderAccess.file,
                bookmarkKey: String = "flux.menuBar.orderingBookmark.v1", message: String? = nil) {
        self.defaults = defaults; self.fileURL = file; self.key = bookmarkKey; self.message = message
        if let data = defaults.data(forKey: key) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.standardizedFileURL == fileURL.standardizedFileURL,
               url.startAccessingSecurityScopedResource() {
                scoped = url
                if stale { save(url) }
            }
        }
    }

    public func request() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.title = "Allow Menu Bar Ordering"
        panel.message = message ?? "Select com.apple.MenuBar.plist to let Flux save icon order. This grants access to this file only."
        panel.prompt = "Allow Ordering"
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL == fileURL.standardizedFileURL else { return false }
        scoped?.stopAccessingSecurityScopedResource()
        scoped = url.startAccessingSecurityScopedResource() ? url : nil
        save(url)
        return true
    }

    deinit { scoped?.stopAccessingSecurityScopedResource() }

    private func save(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                            relativeTo: nil) { defaults.set(data, forKey: key) }
    }
}

@MainActor public final class MenuBarLegacyOrderAccess {
    private static let prefix = "flux.menuBar.legacyOrderingBookmark.v1."
    private let defaults: UserDefaults
    private var files: [ApplicationID: MenuBarOrderAccess] = [:]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            if let app = ApplicationID(rawValue: String(key.dropFirst(Self.prefix.count))) { _ = access(app) }
        }
    }

    public func request(_ app: ApplicationID) -> Bool { access(app)?.request() == true }

    private func access(_ app: ApplicationID) -> MenuBarOrderAccess? {
        if let existing = files[app] { return existing }
        guard let file = Self.file(for: app) else { return nil }
        let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == app.rawValue }?.localizedName ?? "this app"
        let access = MenuBarOrderAccess(defaults: defaults, file: file, bookmarkKey: Self.prefix + app.rawValue,
            message: "Select \(file.lastPathComponent) to read \(name)'s saved menu bar item name. Flux will not change this file.")
        files[app] = access
        return access
    }

    nonisolated static func file(for application: ApplicationID) -> URL? {
        guard application.rawValue.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", options: .regularExpression) != nil else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let container = home.appendingPathComponent("Library/Containers").appendingPathComponent(application.rawValue)
        let directory = FileManager.default.fileExists(atPath: container.path)
            ? container.appendingPathComponent("Data/Library/Preferences") : home.appendingPathComponent("Library/Preferences")
        return directory.appendingPathComponent(application.rawValue + ".plist")
    }
}

public struct MenuBarPositionEdit: Sendable {
    public let key: String
    public let before: Double?
    public let after: Double
}

/// Serialized preference writes. No event posting, cursor APIs or input taps.
public actor MenuBarPositionStore {
    private let preferences: MenuBarContainerPreferences
    private let requiresSystemAnchor: Bool
    private let chevronKey: String?

    public init(chevronKey: String? = nil) {
        self.init(domain: "com.apple.MenuBar", container: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/com.apple.MenuBar"), chevronKey: chevronKey)
    }

    init(domain: String, container: URL, chevronKey: String? = nil) {
        preferences = MenuBarContainerPreferences(domain: domain, key: "TrailingItemPreferredPositions", container: container)
        requiresSystemAnchor = domain == "com.apple.MenuBar"
        self.chevronKey = chevronKey
    }

    private func read() throws(MenuBarMoveFailure) -> [String: Any] {
        guard let raw = preferences.read() as? [String: Any], raw.count <= 4096 else { throw .positionAccessRequired }
        if requiresSystemAnchor, weights(raw)["module:Clock"] == nil { throw .positionAccessRequired }
        return raw
    }

    private func weights(_ raw: [String: Any]) -> [String: Double] {
        raw.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                result[pair.key] = number.doubleValue
            }
        }
    }

    private func resolvedIdentities(_ identities: [MenuBarPositionIdentity]) -> [MenuBarPositionIdentity] {
        var legacy: [ApplicationID: [String: Double]] = [:]
        return identities.map { identity in
            if legacy[identity.item.application] == nil {
                legacy[identity.item.application] = Self.legacyPositions(identity.item.application)
            }
            return MenuBarPositionIdentity(item: identity.item, owners: identity.owners,
                identifier: identity.identifier, siblingCount: identity.siblingCount,
                legacyPositions: identity.legacyPositions.isEmpty ? legacy[identity.item.application]! : identity.legacyPositions)
        }
    }

    private static func legacyPositions(_ application: ApplicationID) -> [String: Double] {
        let prefix = "NSStatusItem Preferred Position "
        let domain = application.rawValue as CFString
        var raw: [String: Any] = [:]
        if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], keys.count <= 4096 {
            for key in keys where key.hasPrefix(prefix) {
                raw[key] = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
        }
        if let file = MenuBarLegacyOrderAccess.file(for: application) {
            if let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
               info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= 1_048_576,
               let data = try? Data(contentsOf: file),
               let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                for (key, value) in values where key.hasPrefix(prefix) && raw[key] == nil { raw[key] = value }
            }
        }
        return raw.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue >= 0 {
                result[String(pair.key.dropFirst(prefix.count))] = number.doubleValue
            }
        }
    }

    public func preferredOrder(identities: [MenuBarPositionIdentity]) throws -> [MenuBarItemID: Double] {
        let positions = weights(try read())
        let identities = resolvedIdentities(identities)
        return identities.reduce(into: [:]) { result, identity in
            if let key = try? MenuBarPositionIdentity.key(for: identity.item, in: identities, keys: Set(positions.keys)),
               let weight = positions[key] ?? key.components(separatedBy: "::").last.flatMap({ identity.legacyPositions[$0] }) { result[identity.item] = weight }
        }
    }

    public func place(_ move: MenuBarItemMove, identities: [MenuBarPositionIdentity]) throws -> MenuBarPositionEdit {
        try Task.checkCancellation()
        guard !move.item.application.isManagedBySystem else { throw MenuBarMoveFailure.itemLocked }
        var raw = try read()
        // Merge with a second current read; never write a saved whole-domain snapshot.
        let fresh = try read()
        if !(raw as NSDictionary).isEqual(to: fresh) { raw = fresh }
        let order = try placement(move, raw: raw, identities: identities)
        let weight = try MenuBarPositionOrder.weight(item: order.item, left: order.left, right: order.right, positions: order.positions)
        try Task.checkCancellation()
        try write(weight, for: order.item, merging: raw)
        return MenuBarPositionEdit(key: order.item, before: weights(raw)[order.item], after: weight)
    }

    public func isPlaced(_ move: MenuBarItemMove, identities: [MenuBarPositionIdentity]) throws -> Bool {
        let raw = try read()
        let order = try placement(move, raw: raw, identities: identities)
        guard weights(raw)[order.item] != nil else { return false }
        return MenuBarPositionOrder.isPlaced(item: order.item, left: order.left, right: order.right, positions: order.positions)
    }

    private func placement(_ move: MenuBarItemMove, raw: [String: Any], identities: [MenuBarPositionIdentity]) throws
        -> (item: String, left: String?, right: String?, positions: [String: Double]) {
        var positions = weights(raw)
        let identities = resolvedIdentities(identities)
        let keys = Set(positions.keys)
        func key(for id: MenuBarItemID) throws -> String {
            do { return try MenuBarPositionIdentity.key(for: id, in: identities, keys: keys) }
            catch MenuBarMoveFailure.positionIdentityUnavailable {
                if identities.first(where: { $0.item == id })?.legacyPositions.isEmpty == true,
                   MenuBarLegacyOrderAccess.file(for: id.application) != nil {
                    throw MenuBarMoveFailure.legacyPositionAccessRequired(id.application)
                }
                throw MenuBarMoveFailure.positionIdentityUnavailable
            }
        }
        let item = try key(for: move.item)
        let leftID = move.intent == .group ? nil : move.left
        let rightID = move.intent == .group ? nil : move.right
        var left = try leftID.map { try key(for: $0) }
        var right = try rightID.map { try key(for: $0) }
        guard item != left, item != right, left == nil || left != right else { throw MenuBarMoveFailure.positionIdentityUnavailable }
        var requested = [(move.item, item)]
        if let id = leftID, let key = left { requested.append((id, key)) }
        if let id = rightID, let key = right { requested.append((id, key)) }
        for (id, key) in requested {
            if positions[key] == nil {
                guard raw[key] == nil, let identity = identities.first(where: { $0.item == id }),
                      let name = key.components(separatedBy: "::").last,
                      let weight = identity.legacyPositions[name] else { throw MenuBarMoveFailure.positionIdentityUnavailable }
                positions[key] = weight
            }
        }
        if let chevronKey {
            guard let boundary = positions[chevronKey], boundary > 0, item != chevronKey else {
                throw MenuBarMoveFailure.positionIdentityUnavailable
            }
            let shown = move.group == .shown
            let onSide = Set(positions.compactMap { key, value -> String? in
                guard value >= 0 else { return nil }
                return (shown ? value < boundary : value > boundary) ? key : nil
            })
            if move.intent == .group || (move.left == nil && move.right == nil) {
                left = nil; right = nil
                if !onSide.contains(item) {
                    if move.group == .shown { left = chevronKey } else { right = chevronKey }
                }
            } else {
                if let key = left, !onSide.contains(key) { left = nil }
                if let key = right, !onSide.contains(key) { right = nil }
                if move.group == .shown, left == nil { left = chevronKey }
                if move.group != .shown, right == nil { right = chevronKey }
            }
        }
        return (item, left, right, positions)
    }

    public func restore(_ edit: MenuBarPositionEdit) throws {
        let fresh = try read()
        guard weights(fresh)[edit.key] == edit.after else { return }
        try write(edit.before, for: edit.key, merging: fresh)
    }

    private func write(_ value: Double?, for item: String, merging raw: [String: Any]) throws(MenuBarMoveFailure) {
        var merged = raw
        merged[item] = value
        guard preferences.write(merged as CFDictionary),
              weights(try read())[item] == value else { throw .notAccepted }
    }
}
