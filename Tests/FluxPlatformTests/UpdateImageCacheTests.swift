import Foundation
import Testing
import FluxCore
@testable import FluxPlatform

struct UpdateImageCacheTests {
    private func release(_ version: String = "0.22.0") throws -> ReleaseManifest {
        try ReleaseManifest(data: Data("""
        {"tag_name":"v\(version)","draft":false,"prerelease":false,"assets":[{"name":"Flux.dmg","state":"uploaded","size":8,"browser_download_url":"https://github.com/unknown6003/flux/releases/download/v\(version)/Flux.dmg"}]}
        """.utf8))
    }

    @Test func cacheReuseRechecksBytesAndDoesNotClobberEditedOrLinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flux-cache-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("Flux.dmg")
        let original = Data("12345678".utf8)
        try original.write(to: disk)
        let manifest = try release()
        // This control tests cache bytes only. It does not accept a signed DMG.
        let cache = try UpdateImageCache(verifiedFile: disk, release: manifest)
        #expect(try cache.validatedFile(for: manifest) == disk)
        #expect(try cache.validatedFile(for: release("0.22.1")) == nil)
        try Data("87654321".utf8).write(to: disk)
        #expect(try cache.validatedFile(for: manifest) == nil)
        #expect(try Data(contentsOf: disk) == Data("87654321".utf8))
        try FileManager.default.removeItem(at: disk)
        let target = root.appendingPathComponent("original.dmg")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: target)
        #expect(throws: ReleaseDownloadError.file) { try cache.validatedFile(for: manifest) }
        #expect(try Data(contentsOf: target) == original)
        try FileManager.default.removeItem(at: disk)
        #expect(throws: ReleaseDownloadError.file) { try cache.validatedFile(for: manifest) }
    }
}
