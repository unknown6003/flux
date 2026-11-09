import Foundation
import Testing
@testable import FluxCore

struct ReleaseManifestTests {
    private static let release = #"{"tag_name":"v0.22.0","draft":false,"prerelease":false,"body":"Release notes","assets":[{"name":"Flux.dmg","state":"uploaded","size":1048576,"browser_download_url":"https://github.com/unknown6003/flux/releases/download/v0.22.0/Flux.dmg","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}"#

    @Test func numericVersionsDoNotCompareAsStringsOrAcceptMalformedVersions() throws {
        #expect(try #require(ReleaseVersion("0.22.0")) > #require(ReleaseVersion("0.9.99")))
        #expect(try #require(ReleaseVersion("v0.22.0")) == #require(ReleaseVersion("0.22.0")))
        for bad in ["", "0.22", "0.22.0.1", "0.22.-1", "00.22.0", "0.22.0-beta", "0.22.4294967296", "0.٢٢.0"] {
            #expect(ReleaseVersion(bad) == nil)
        }
    }

    @Test func releaseIsBoundToItsPublishedTagRepositoryAndExactDiskImage() throws {
        let release = try ReleaseManifest(data: Data(Self.release.utf8))
        #expect(release.version.description == "0.22.0")
        #expect(release.size == 1_048_576)
        #expect(release.sha256?.count == 64)
        #expect(release.downloadURL.lastPathComponent == "Flux.dmg")
        for (original, replacement) in [
            (#""draft":false"#, #""draft":true"#),
            (#""prerelease":false"#, #""prerelease":true"#),
            ("github.com/unknown6003", "github.com/another-owner"),
            ("https://github.com/", "https://github.com.attacker.invalid/"),
            ("/download/v0.22.0/", "/download/v0.23.0/"),
            (#""size":1048576"#, #""size":134217729"#),
            (#""size":1048576"#, #""size":true"#),
            (#""state":"uploaded""#, #""state":"new""#),
            ("sha256:0123", "sha256:xyz3")
        ] {
            #expect(throws: (any Error).self) {
                try ReleaseManifest(data: Data(Self.release.replacingOccurrences(of: original, with: replacement).utf8))
            }
        }
    }

    @Test func versionedDiskImageIsPreferredAndMustMatchTheTag() throws {
        let versioned = Self.release.replacingOccurrences(of: "Flux.dmg", with: "Flux-0.22.0.dmg")
        #expect(try ReleaseManifest(data: Data(versioned.utf8)).downloadURL.lastPathComponent == "Flux-0.22.0.dmg")
        #expect(throws: (any Error).self) {
            try ReleaseManifest(data: Data(Self.release.replacingOccurrences(of: "Flux.dmg", with: "Flux-0.21.0.dmg").utf8))
        }
    }
}
