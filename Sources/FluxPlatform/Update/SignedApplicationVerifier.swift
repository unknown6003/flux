import Foundation
import Security
import FluxCore

public enum SignedApplicationError: Error, Equatable { case signature, metadata }

/// Run against a private staged copy. Validation remains true only while
/// that copy stays unchanged. The installer owns staging and atomic handoff.
public actor SignedApplicationVerifier {
    // Code requirements use the certificate's SHA-1 fingerprint. This pins
    // the existing Flux leaf, rather than accepting any self-signed app.
    private static let requirementText = #"identifier "com.flux.menubar" and certificate leaf = H"A7378EAF65FB4E0A254BAA69167FB772C9DFFBBC""#

    public init() {}

    public func verify(_ candidate: URL, expectedVersion: ReleaseVersion) throws {
        try Task.checkCancellation()
        guard candidate.isFileURL, candidate.pathExtension == "app" else { throw SignedApplicationError.metadata }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let standard = SecCSFlags(rawValue: kSecCSDefaultFlags)
        guard SecStaticCodeCreateWithPath(candidate as CFURL, standard, &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(Self.requirementText as CFString, standard, &requirement) == errSecSuccess,
              let requirement else { throw SignedApplicationError.signature }
        let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else {
            throw SignedApplicationError.signature
        }
        try Task.checkCancellation()
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "com.flux.menubar",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion.description,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              UInt32(build) != nil,
              bundle.executableURL?.lastPathComponent == "Flux",
              bundle.object(forInfoDictionaryKey: "FluxProbeOnly") == nil,
              bundle.object(forInfoDictionaryKey: "FluxLayoutProbeOnly") == nil else {
            throw SignedApplicationError.metadata
        }
    }
}
