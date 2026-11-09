import Foundation

public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    private let parts: [UInt32]
    public var description: String { parts.map(String.init).joined(separator: ".") }

    public init?(_ value: String) {
        guard value.utf8.count <= 34 else { return nil }
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let strings = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard strings.count == 3, strings.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }) else { return nil }
        let parts = strings.compactMap { UInt32($0) }
        guard parts.count == 3 else { return nil }
        self.parts = parts
    }

    public static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

public enum ReleaseManifestError: Error { case oversized, invalidRelease, invalidAsset }

/// One published Flux release. Paths are derived from the checked tag, so
/// fields in a release response cannot point the installer at another origin.
public struct ReleaseManifest: Equatable, Sendable {
    public static let maximumResponseBytes = 1_048_576
    public static let maximumDownloadBytes: Int64 = 128 * 1024 * 1024
    public let version: ReleaseVersion
    public let notes: String
    public let pageURL: URL
    public let downloadURL: URL
    public let size: Int64
    public let sha256: String?

    public init(data: Data) throws {
        guard data.count <= Self.maximumResponseBytes else { throw ReleaseManifestError.oversized }
        let release = try JSONDecoder().decode(Response.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = ReleaseVersion(release.tag_name),
              release.tag_name == "v" + version.description,
              release.assets.count <= 256 else { throw ReleaseManifestError.invalidRelease }
        // From 0.22.2 the image is "Flux-<version>.dmg". Flux 0.22.0 and 0.22.1
        // accept only "Flux.dmg" and hang when their updater quits, so the new
        // name keeps them from trying. Flux 0.21.35 takes any .dmg asset.
        let versioned = "Flux-\(version.description).dmg"
        let named = release.assets.filter { $0.name == versioned }
        let assets = named.isEmpty ? release.assets.filter { $0.name == "Flux.dmg" } : named
        guard assets.count == 1, let asset = assets.first, asset.state == "uploaded",
              asset.size > 0, asset.size <= Self.maximumDownloadBytes else { throw ReleaseManifestError.invalidAsset }
        let expected = "https://github.com/unknown6003/flux/releases/download/\(release.tag_name)/\(asset.name)"
        guard asset.browser_download_url == expected,
              let download = URL(string: expected),
              let page = URL(string: "https://github.com/unknown6003/flux/releases/tag/\(release.tag_name)") else {
            throw ReleaseManifestError.invalidAsset
        }
        var digest: String?
        if let raw = asset.digest {
            let hex = raw.dropFirst(7)
            guard raw.hasPrefix("sha256:"), hex.utf8.count == 64,
                  hex.allSatisfy({ $0.isASCII && ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                throw ReleaseManifestError.invalidAsset
            }
            digest = String(hex)
        }
        self.version = version
        notes = String((release.body ?? "").prefix(10_000))
        pageURL = page
        downloadURL = download
        size = asset.size
        sha256 = digest
    }

    private struct Response: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int64
        let browser_download_url: String
        let digest: String?
    }
}
