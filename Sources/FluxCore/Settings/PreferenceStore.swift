import Foundation

public enum ProfileOrigin: String, Sendable {
    case new, upgrade
}

/// The caller inspects existing Flux files and valid updater arguments before migration.
public struct InstallationEvidence: Sendable {
    public var hasExistingData: Bool
    public var isUpdateLaunch: Bool

    public init(hasExistingData: Bool = false, isUpdateLaunch: Bool = false) {
        self.hasExistingData = hasExistingData
        self.isUpdateLaunch = isUpdateLaunch
    }
}

public struct PreferenceMigration {
    public static let originKey = "flux.native.profileOrigin.v1"
    public let origin: ProfileOrigin
    public let missingValues: [String: Any]

    public init(persisted: [String: Any], evidence: InstallationEvidence) {
        if let saved = persisted[Self.originKey] as? String,
           let origin = ProfileOrigin(rawValue: saved) {
            self.origin = origin
        } else {
            let hasPreferences = persisted.keys.contains {
                $0.hasPrefix("flux.") || $0.hasPrefix("NSStatusItem Preferred Position flux.")
            }
            origin = hasPreferences || evidence.hasExistingData || evidence.isUpdateLaunch ? .upgrade : .new
        }
        var missing: [String: Any] = [:]
        for preference in Preferences.registrations where persisted[preference.key] == nil {
            missing[preference.key] = preference.value(origin == .new)
        }
        missingValues = missing
    }
}

/// All changes enter through the main actor. No timer or observation task is started here.
@MainActor public final class PreferenceStore {
    private let defaults: UserDefaults
    private let domain: String
    public let origin: ProfileOrigin

    public init(defaults: UserDefaults, domain: String, evidence: InstallationEvidence) {
        self.defaults = defaults
        self.domain = domain
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        let migration = PreferenceMigration(persisted: persisted, evidence: evidence)
        origin = migration.origin
        // Write this first so a stopped first launch still uses new-profile defaults on retry.
        defaults.set(origin.rawValue, forKey: PreferenceMigration.originKey)
        for (key, value) in migration.missingValues {
            // Keep an edit made after the initial snapshot. Do not replace the whole domain.
            if defaults.persistentDomain(forName: domain)?[key] == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    public func value<Value>(for preference: Preference<Value>) -> Value {
        let raw = defaults.persistentDomain(forName: domain)?[preference.key]
        // A malformed privacy switch must not start collection or private-screen work.
        return preference.value(from: raw) ?? preference.newProfileDefault
    }

    public func set<Value>(_ value: Value, for preference: Preference<Value>) throws {
        defaults.set(try preference.propertyList(value), forKey: preference.key)
    }
}
