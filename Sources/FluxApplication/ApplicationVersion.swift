import Foundation

/// Shared bundle values for Settings and the updater. The production bundle
/// keeps the existing Flux identifier, executable name and signing identity.
public struct ApplicationVersion: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
