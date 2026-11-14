import AppKit
import FluxCore

/// Access is limited to the menu bar's position file, selected by the user.
@MainActor public final class MenuBarOrderAccess {
    private let defaults: UserDefaults
    private let key: String
    private let fileURL: URL
    private var scoped: URL?
    public static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    public static var visibilityFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    public init(defaults: UserDefaults, file: URL = MenuBarOrderAccess.file,
                bookmarkKey: String = "flux.menuBar.orderingBookmark.v1") {
        self.defaults = defaults; self.fileURL = file; self.key = bookmarkKey
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
        panel.message = fileURL == Self.visibilityFile
            ? "Select group.com.apple.controlcenter.plist to let Flux reveal hidden icons during ordering. Their visibility is restored after the move. This grants access to this file only."
            : "Select com.apple.MenuBar.plist to let Flux save icon order. This grants access to this file only."
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

public struct MenuBarPositionEdit: Sendable {
    public let key: String
    public let before: Double?
    public let after: Double
}

/// Serialized preference writes. No event posting, cursor APIs or input taps.
public actor MenuBarPositionStore {
    private let preferences: MenuBarContainerPreferences
    private let requiresSystemAnchor: Bool

    public init() {
        self.init(domain: "com.apple.MenuBar", container: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/com.apple.MenuBar"))
    }

    init(domain: String, container: URL) {
        preferences = MenuBarContainerPreferences(domain: domain, key: "TrailingItemPreferredPositions", container: container)
        requiresSystemAnchor = domain == "com.apple.MenuBar"
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
        if application.rawValue.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", options: .regularExpression) != nil {
            let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers")
                .appendingPathComponent(application.rawValue).appendingPathComponent("Data/Library/Preferences")
                .appendingPathComponent(application.rawValue + ".plist")
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
        var positions = weights(raw)
        let identities = resolvedIdentities(identities)
        let keys = Set(positions.keys)
        let item = try MenuBarPositionIdentity.key(for: move.item, in: identities, keys: keys)
        let left = try move.left.map { try MenuBarPositionIdentity.key(for: $0, in: identities, keys: keys) }
        let right = try move.right.map { try MenuBarPositionIdentity.key(for: $0, in: identities, keys: keys) }
        guard item != left, item != right, left == nil || left != right else { throw MenuBarMoveFailure.positionIdentityUnavailable }
        let before = positions[item]
        var requested = [(move.item, item)]
        if let id = move.left, let key = left { requested.append((id, key)) }
        if let id = move.right, let key = right { requested.append((id, key)) }
        for (id, key) in requested {
            if positions[key] == nil {
                guard raw[key] == nil, let identity = identities.first(where: { $0.item == id }),
                      let name = key.components(separatedBy: "::").last,
                      let weight = identity.legacyPositions[name] else { throw MenuBarMoveFailure.positionIdentityUnavailable }
                positions[key] = weight
            }
        }
        let weight = try MenuBarPositionOrder.weight(item: item, left: left, right: right, positions: positions)
        try Task.checkCancellation()
        try write(weight, for: item, merging: raw)
        return MenuBarPositionEdit(key: item, before: before, after: weight)
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
