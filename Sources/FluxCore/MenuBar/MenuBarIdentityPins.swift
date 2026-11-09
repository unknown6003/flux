import Foundation
import CoreFoundation

public enum MenuBarIdentityError: Error {
    case invalidStoredPins
    case invalidRequirement
    case tooManyApplications
    case protectedApplication
}

/// Local signing requirements are separate from visibility choices. They never
/// enter telemetry. Keep unknown fields when writing a newer preference value.
public struct MenuBarIdentityPins: Sendable, Equatable {
    public static let maximumApplications = 256
    public static let maximumRequirementBytes = 16_384
    private var requirements: [ApplicationID: Data] = [:]

    public init() {}

    public init(propertyList value: Any?) throws {
        guard let value else { return }
        guard let dictionary = value as? [String: Any], let version = dictionary["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let stored = dictionary["requirements"] as? [String: Data],
              stored.count <= Self.maximumApplications else { throw MenuBarIdentityError.invalidStoredPins }
        for (raw, data) in stored {
            guard let application = ApplicationID(rawValue: raw), !application.isManagedBySystem,
                  !data.isEmpty, data.count <= Self.maximumRequirementBytes else {
                throw MenuBarIdentityError.invalidStoredPins
            }
            requirements[application] = data
        }
    }

    public func requirement(for application: ApplicationID) -> Data? { requirements[application] }

    public mutating func trust(_ application: ApplicationID, requirement: Data) throws {
        guard !application.isManagedBySystem else { throw MenuBarIdentityError.protectedApplication }
        guard !requirement.isEmpty, requirement.count <= Self.maximumRequirementBytes else {
            throw MenuBarIdentityError.invalidRequirement
        }
        guard requirements[application] != nil || requirements.count < Self.maximumApplications else {
            throw MenuBarIdentityError.tooManyApplications
        }
        requirements[application] = requirement
    }

    public func propertyList(updating original: [String: Any] = [:]) -> [String: Any] {
        var result = original
        result["version"] = 1
        result["requirements"] = Dictionary(uniqueKeysWithValues: requirements.map { ($0.key.rawValue, $0.value) })
        return result
    }
}
