import Foundation
import Security
import FluxCore

public struct MenuBarIdentityEvidence: Sendable, Equatable {
    public let requirement: Data
    public let matchesSaved: Bool

    public init(requirement: Data, matchesSaved: Bool) {
        self.requirement = requirement
        self.matchesSaved = matchesSaved
    }
}

/// Dynamic code validation runs off the main actor and forbids network checks.
/// A requirement copied from disk is accepted only if the running code also
/// satisfies it. This is identity continuity, not a notarization verdict.
public actor MenuBarIdentityReader {
    public init() {}

    public func read(processID: pid_t, application: ApplicationID,
                     savedRequirement: Data?) -> MenuBarIdentityEvidence? {
        guard processID > 0, !application.isManagedBySystem, !Task.isCancelled else { return nil }
        var dynamic: SecCode?
        let attributes = [kSecGuestAttributePid: processID] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamic) == errSecSuccess,
              let dynamic else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == application.rawValue else { return nil }
        var current: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &current) == errSecSuccess,
              let current else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSNoNetworkAccess)
        guard SecCodeCheckValidity(dynamic, flags, current) == errSecSuccess else { return nil }
        var data: CFData?
        guard SecRequirementCopyData(current, [], &data) == errSecSuccess, let data else { return nil }
        let requirement = data as Data
        guard !requirement.isEmpty, requirement.count <= MenuBarIdentityPins.maximumRequirementBytes,
              !Task.isCancelled else { return nil }
        guard let savedRequirement else { return .init(requirement: requirement, matchesSaved: true) }
        guard !savedRequirement.isEmpty, savedRequirement.count <= MenuBarIdentityPins.maximumRequirementBytes else { return nil }
        var saved: SecRequirement?
        guard SecRequirementCreateWithData(savedRequirement as CFData, [], &saved) == errSecSuccess,
              let saved else { return nil }
        let status = SecCodeCheckValidity(dynamic, flags, saved)
        guard !Task.isCancelled, status == errSecSuccess || status == errSecCSReqFailed else { return nil }
        return .init(requirement: requirement, matchesSaved: status == errSecSuccess)
    }
}
