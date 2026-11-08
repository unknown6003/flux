import CoreFoundation
import Foundation

public enum NativeVisibilityError: Error {
    case malformed, missingApplication, protectedApplication, ambiguousOwner
    case unsupportedLocation, unexpectedAllowance, changedIdentity
}

public struct NativeVisibilityEntry: Sendable {
    public let allowed: Bool
    public let identity: Data
}

/// A journal entry is saved before the platform writes its temporary override.
/// It never contains an entire system preference snapshot to restore later.
public struct NativeVisibilityLease: Codable, Sendable {
    public let application: ApplicationID
    public let original: Bool
    public let written: Bool
    public let identity: Data
    public let transaction: UUID

    public init(application: ApplicationID, entry: NativeVisibilityEntry, written: Bool, transaction: UUID = UUID()) {
        self.application = application
        original = entry.allowed
        self.written = written
        identity = entry.identity
        self.transaction = transaction
    }
}

/// The native macOS27 value is an alternating location/value property list.
/// Keep it as bytes across actors; edits decode a fresh value and preserve
/// every unowned field and the row order. No system preference I/O occurs here.
public struct NativeVisibilityDocument: Sendable {
    public let data: Data
    public init(data: Data) throws {
        _ = try Self.rows(data)
        self.data = data
    }

    public func inspect(_ application: ApplicationID, executableURLs: [URL] = []) throws -> NativeVisibilityEntry {
        let rows = try Self.rows(data)
        let row = try Self.target(application, in: rows)
        var candidates = try Self.locations(row)
        candidates.formUnion(executableURLs.map { .binary($0.standardizedFileURL.path) })
        for other in rows where other.offset != row.offset {
            guard try Self.locations(other).isDisjoint(with: candidates) else { throw NativeVisibilityError.ambiguousOwner }
        }
        guard let location = row.value["location"], let items = row.value["menuItemLocations"] else {
            throw NativeVisibilityError.unsupportedLocation
        }
        let identity = try PropertyListSerialization.data(fromPropertyList: [
            "key": row.key, "location": location, "menuItemLocations": items
        ], format: .binary, options: 0)
        return .init(allowed: try Self.allowance(row.value), identity: identity)
    }

    public func applying(_ lease: NativeVisibilityLease, executableURLs: [URL] = []) throws -> Self {
        try changing(lease, expected: lease.original, desired: lease.written, executableURLs: executableURLs)
    }

    public func restoring(_ lease: NativeVisibilityLease, executableURLs: [URL] = []) throws -> Self {
        let entry = try inspect(lease.application, executableURLs: executableURLs)
        // Someone has already restored the original value. Do not reapply an override.
        if entry.allowed == lease.original { return self }
        return try changing(lease, expected: lease.written, desired: lease.original, executableURLs: executableURLs)
    }

    private func changing(_ lease: NativeVisibilityLease, expected: Bool, desired: Bool, executableURLs: [URL]) throws -> Self {
        let entry = try inspect(lease.application, executableURLs: executableURLs)
        guard entry.allowed == expected else { throw NativeVisibilityError.unexpectedAllowance }
        let currentIdentity = try PropertyListSerialization.propertyList(from: entry.identity, options: [], format: nil)
        let savedIdentity = try PropertyListSerialization.propertyList(from: lease.identity, options: [], format: nil)
        guard let current = currentIdentity as? NSDictionary, let saved = savedIdentity as? NSDictionary,
              current.isEqual(saved) else { throw NativeVisibilityError.changedIdentity }
        var array = try Self.array(data)
        let row = try Self.target(lease.application, in: Self.rows(data))
        var value = row.value
        value["isAllowed"] = desired
        array[row.offset + 1] = value
        return try Self(data: PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0))
    }

    private struct Row {
        let offset: Int
        let key: [String: Any]
        let value: [String: Any]
    }

    private enum Location: Hashable {
        case bundle(ApplicationID)
        case binary(String)
    }

    private static func array(_ data: Data) throws -> [Any] {
        guard data.count <= 8 * 1024 * 1024,
              let array = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any],
              array.count.isMultiple(of: 2) else { throw NativeVisibilityError.malformed }
        return array
    }

    private static func rows(_ data: Data) throws -> [Row] {
        let values = try array(data)
        return try stride(from: 0, to: values.count, by: 2).map { offset in
            guard let key = values[offset] as? [String: Any],
                  let value = values[offset + 1] as? [String: Any] else { throw NativeVisibilityError.malformed }
            _ = try allowance(value)
            return Row(offset: offset, key: key, value: value)
        }
    }

    private static func allowance(_ value: [String: Any]) throws -> Bool {
        guard let number = value["isAllowed"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativeVisibilityError.malformed }
        return number.boolValue
    }

    private static func target(_ application: ApplicationID, in rows: [Row]) throws -> Row {
        guard !application.isManagedBySystem else { throw NativeVisibilityError.protectedApplication }
        let matches = rows.filter {
            ($0.key["bundle"] as? [String: Any])?["_0"] as? String == application.rawValue
        }
        guard !matches.isEmpty else { throw NativeVisibilityError.missingApplication }
        guard matches.count == 1 else { throw NativeVisibilityError.ambiguousOwner }
        return matches[0]
    }

    private static func locations(_ row: Row) throws -> Set<Location> {
        guard let location = row.value["location"] as? [String: Any],
              let items = row.value["menuItemLocations"] as? [[String: Any]] else {
            throw NativeVisibilityError.unsupportedLocation
        }
        return try Set(([row.key, location] + items).map(parseLocation))
    }

    private static func parseLocation(_ value: [String: Any]) throws -> Location {
        guard value.count == 1 else { throw NativeVisibilityError.unsupportedLocation }
        if let bundle = value["bundle"] as? [String: Any],
           let raw = bundle["_0"] as? String, let application = ApplicationID(rawValue: raw) {
            return .bundle(application)
        }
        if let binary = value["adhocBinary"] as? [String: Any],
           let encodedURL = binary["_0"] as? [String: Any],
           let relative = encodedURL["relative"] as? String {
            if let url = URL(string: relative), url.isFileURL {
                return .binary(url.standardizedFileURL.path)
            }
            if relative.hasPrefix("/") { return .binary(URL(fileURLWithPath: relative).standardizedFileURL.path) }
        }
        throw NativeVisibilityError.unsupportedLocation
    }
}
