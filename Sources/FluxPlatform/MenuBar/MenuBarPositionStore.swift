import AppKit
import FluxCore

/// Access is limited to the menu bar's position file, selected by the user.
@MainActor public final class MenuBarOrderAccess {
    private let defaults: UserDefaults
    private let key = "flux.menuBar.orderingBookmark.v1"
    private var scoped: URL?
    public static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.standardizedFileURL == Self.file.standardizedFileURL,
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
        panel.directoryURL = Self.file.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.file.lastPathComponent
        panel.title = "Allow Menu Bar Ordering"
        panel.message = "Select com.apple.MenuBar.plist to let Flux save icon order. This grants access to this file only."
        panel.prompt = "Allow Ordering"
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL == Self.file.standardizedFileURL else { return false }
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
    public let before: Double
    public let after: Double
}

/// Serialized preference writes. No event posting, cursor APIs or input taps.
public actor MenuBarPositionStore {
    private typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFTypeRef>?
    private typealias SetValue = @convention(c) (CFString, CFTypeRef?, CFString, CFString, CFString, CFString) -> Void
    private typealias Sync = @convention(c) (CFString, CFString, CFString, CFString) -> Bool
    private let copy: Copy?
    private let set: SetValue?
    private let sync: Sync?
    private let domain: CFString
    private let key = "TrailingItemPreferredPositions" as CFString
    private let container: CFString

    public init() {
        self.init(domain: "com.apple.MenuBar", container: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/com.apple.MenuBar"))
    }

    init(domain: String, container: URL) {
        self.domain = domain as CFString
        self.container = container.path as CFString
        let library = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW)
        copy = library.flatMap { dlsym($0, "_CFPreferencesCopyValueWithContainer") }.map { unsafeBitCast($0, to: Copy.self) }
        set = library.flatMap { dlsym($0, "_CFPreferencesSetValueWithContainer") }.map { unsafeBitCast($0, to: SetValue.self) }
        sync = library.flatMap { dlsym($0, "_CFPreferencesSynchronizeWithContainer") }.map { unsafeBitCast($0, to: Sync.self) }
    }

    private func read() throws(MenuBarMoveFailure) -> [String: Any] {
        guard let copy, let sync else { throw .positionAccessRequired }
        guard sync(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container) else { throw .positionAccessRequired }
        guard let raw = copy(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)?.takeRetainedValue()
                as? [String: Any], raw.count <= 4096 else { throw .positionAccessRequired }
        return raw
    }

    private func weights(_ raw: [String: Any]) -> [String: Double] {
        raw.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                result[pair.key] = number.doubleValue
            }
        }
    }

    public func place(_ move: MenuBarItemMove, identities: [MenuBarPositionIdentity]) throws -> MenuBarPositionEdit {
        try Task.checkCancellation()
        guard !move.item.application.isManagedBySystem else { throw MenuBarMoveFailure.itemLocked }
        var raw = try read()
        // Merge with a second current read; never write a saved whole-domain snapshot.
        let fresh = try read()
        if !(raw as NSDictionary).isEqual(to: fresh) { raw = fresh }
        let positions = weights(raw)
        let keys = Set(positions.keys)
        let item = try MenuBarPositionIdentity.key(for: move.item, in: identities, keys: keys)
        let left = try move.left.map { try MenuBarPositionIdentity.key(for: $0, in: identities, keys: keys) }
        let right = try move.right.map { try MenuBarPositionIdentity.key(for: $0, in: identities, keys: keys) }
        guard item != left, item != right, left == nil || left != right else { throw MenuBarMoveFailure.positionIdentityUnavailable }
        let weight = try MenuBarPositionOrder.weight(item: item, left: left, right: right, positions: positions)
        let before = positions[item]!
        try Task.checkCancellation()
        try write(weight, for: item, merging: raw)
        return MenuBarPositionEdit(key: item, before: before, after: weight)
    }

    public func restore(_ edit: MenuBarPositionEdit) throws {
        let fresh = try read()
        guard weights(fresh)[edit.key] == edit.after else { return }
        try write(edit.before, for: edit.key, merging: fresh)
    }

    private func write(_ value: Double, for item: String, merging raw: [String: Any]) throws(MenuBarMoveFailure) {
        guard let set, let sync else { throw .positionAccessRequired }
        var merged = raw
        merged[item] = value
        set(key, merged as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        guard sync(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container),
              weights(try read())[item] == value else { throw .notAccepted }
    }
}
